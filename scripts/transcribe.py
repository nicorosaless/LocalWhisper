#!/usr/bin/env python3
"""
Persistent Qwen3-ASR transcription server for LocalWhisper.

Protocol (over stdin/stdout):
  - Swift sends a JSON line:  {"wav": "/path/to/file.wav", "language": "English"}
  - Python replies with a JSON line:  {"text": "transcribed text"}
  - On error:  {"error": "description"}
  - Special commands:
    - {"cmd": "ping"}  ->  {"status": "ready"}
    - {"cmd": "quit"}  ->  process exits

The model is loaded once at startup. Subsequent transcriptions reuse it,
avoiding the ~2-3s model load overhead per request.

Usage:
    python3 transcribe.py --model-dir /path/to/model/weights
    python3 transcribe.py --model-dir /path/to/model/weights --warmup
"""

import argparse
import glob
import json
import math
import os
import sys
import time
import warnings
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

# Suppress noisy warnings before importing heavy libraries
warnings.filterwarnings("ignore", category=UserWarning)
warnings.filterwarnings("ignore", category=DeprecationWarning)
warnings.filterwarnings("ignore", category=FutureWarning)
os.environ["PYTHONWARNINGS"] = "ignore"
os.environ["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
os.environ["TRANSFORMERS_NO_ADVISORY_WARNINGS"] = "1"
os.environ["TRANSFORMERS_VERBOSITY"] = "error"

import mlx.core as mx

if hasattr(mx, "set_warnings_enabled"):
    mx.set_warnings_enabled(False)

import mlx.nn as nn
import numpy as np


# =============================================================================
# Configuration Classes
# =============================================================================


class AudioEncoderConfig:
    def __init__(self, **kwargs):
        self.num_mel_bins = kwargs.get("num_mel_bins", 128)
        self.encoder_layers = kwargs.get("encoder_layers", 24)
        self.encoder_attention_heads = kwargs.get("encoder_attention_heads", 16)
        self.encoder_ffn_dim = kwargs.get("encoder_ffn_dim", 4096)
        self.d_model = kwargs.get("d_model", 1024)
        self.scale_embedding = kwargs.get("scale_embedding", False)
        self.max_source_positions = kwargs.get("max_source_positions", 1500)
        self.n_window = kwargs.get("n_window", 50)
        self.output_dim = kwargs.get("output_dim", 2048)
        self.n_window_infer = kwargs.get("n_window_infer", 800)
        self.conv_chunksize = kwargs.get("conv_chunksize", 500)
        self.downsample_hidden_size = kwargs.get("downsample_hidden_size", 480)


class TextConfig:
    def __init__(self, **kwargs):
        self.vocab_size = kwargs.get("vocab_size", 151936)
        self.hidden_size = kwargs.get("hidden_size", 2048)
        self.intermediate_size = kwargs.get("intermediate_size", 6144)
        self.num_hidden_layers = kwargs.get("num_hidden_layers", 28)
        self.num_attention_heads = kwargs.get("num_attention_heads", 16)
        self.num_key_value_heads = kwargs.get("num_key_value_heads", 8)
        self.head_dim = kwargs.get("head_dim", 128)
        self.rms_norm_eps = kwargs.get("rms_norm_eps", 1e-6)
        self.tie_word_embeddings = kwargs.get("tie_word_embeddings", True)
        self.rope_theta = kwargs.get("rope_theta", 1000000.0)


class ModelConfig:
    def __init__(
        self,
        audio_config=None,
        text_config=None,
        audio_token_id=151676,
        support_languages=None,
    ):
        if audio_config is None:
            self.audio_config = AudioEncoderConfig()
        elif isinstance(audio_config, dict):
            self.audio_config = AudioEncoderConfig(
                **{
                    k: v
                    for k, v in audio_config.items()
                    if k in AudioEncoderConfig.__init__.__code__.co_varnames
                }
            )
        else:
            self.audio_config = audio_config

        if text_config is None:
            self.text_config = TextConfig()
        elif isinstance(text_config, dict):
            self.text_config = TextConfig(
                **{
                    k: v
                    for k, v in text_config.items()
                    if k in TextConfig.__init__.__code__.co_varnames
                }
            )
        else:
            self.text_config = text_config

        self.audio_token_id = audio_token_id
        self.support_languages = support_languages or []


# =============================================================================
# Model Architecture (from stt.py reference)
# =============================================================================


def create_additive_causal_mask(N: int, offset: int = 0) -> mx.array:
    rinds = mx.arange(offset + N)
    linds = mx.arange(offset, offset + N) if offset else rinds
    mask = linds[:, None] < rinds[None]
    return mask * -1e9


def _floor_div(a: mx.array, b: int) -> mx.array:
    return mx.floor(a.astype(mx.float32) / b).astype(mx.int32)


def _get_feat_extract_output_lengths(input_lengths: mx.array) -> mx.array:
    input_lengths_leave = input_lengths % 100
    feat_lengths = _floor_div(input_lengths_leave - 1, 2) + 1
    output_lengths = (
        _floor_div(_floor_div(feat_lengths - 1, 2) + 1 - 1, 2)
        + 1
        + (input_lengths // 100) * 13
    )
    return output_lengths


class SinusoidalPositionEmbedding(nn.Module):
    def __init__(self, length: int, channels: int, max_timescale: float = 10000.0):
        super().__init__()
        log_timescale_increment = math.log(max_timescale) / (channels // 2 - 1)
        inv_timescales = mx.exp(
            -log_timescale_increment * mx.arange(channels // 2, dtype=mx.float32)
        )
        positions = mx.arange(length, dtype=mx.float32)[:, None]
        scaled_time = positions * inv_timescales[None, :]
        self._positional_embedding = mx.concatenate(
            [mx.sin(scaled_time), mx.cos(scaled_time)], axis=1
        )

    def __call__(self, seqlen: int) -> mx.array:
        return self._positional_embedding[:seqlen, :]


class AudioAttention(nn.Module):
    def __init__(self, config: AudioEncoderConfig):
        super().__init__()
        self.embed_dim = config.d_model
        self.num_heads = config.encoder_attention_heads
        self.head_dim = self.embed_dim // self.num_heads
        self.scaling = self.head_dim**-0.5
        self.q_proj = nn.Linear(self.embed_dim, self.embed_dim, bias=True)
        self.k_proj = nn.Linear(self.embed_dim, self.embed_dim, bias=True)
        self.v_proj = nn.Linear(self.embed_dim, self.embed_dim, bias=True)
        self.out_proj = nn.Linear(self.embed_dim, self.embed_dim, bias=True)

    def __call__(self, hidden_states: mx.array, mask=None) -> mx.array:
        bsz, seq_len, _ = hidden_states.shape
        queries = self.q_proj(hidden_states) * self.scaling
        keys = self.k_proj(hidden_states)
        values = self.v_proj(hidden_states)
        queries = queries.reshape(
            bsz, seq_len, self.num_heads, self.head_dim
        ).transpose(0, 2, 1, 3)
        keys = keys.reshape(bsz, seq_len, self.num_heads, self.head_dim).transpose(
            0, 2, 1, 3
        )
        values = values.reshape(bsz, seq_len, self.num_heads, self.head_dim).transpose(
            0, 2, 1, 3
        )
        attn_output = mx.fast.scaled_dot_product_attention(
            queries, keys, values, scale=1.0, mask=mask
        )
        attn_output = attn_output.transpose(0, 2, 1, 3).reshape(
            bsz, seq_len, self.embed_dim
        )
        return self.out_proj(attn_output)


class AudioEncoderLayer(nn.Module):
    def __init__(self, config: AudioEncoderConfig):
        super().__init__()
        self.embed_dim = config.d_model
        self.self_attn = AudioAttention(config)
        self.self_attn_layer_norm = nn.LayerNorm(self.embed_dim)
        self.fc1 = nn.Linear(self.embed_dim, config.encoder_ffn_dim)
        self.fc2 = nn.Linear(config.encoder_ffn_dim, self.embed_dim)
        self.final_layer_norm = nn.LayerNorm(self.embed_dim)

    def __call__(self, hidden_states: mx.array, mask=None) -> mx.array:
        residual = hidden_states
        hidden_states = self.self_attn_layer_norm(hidden_states)
        hidden_states = self.self_attn(hidden_states, mask=mask)
        hidden_states = residual + hidden_states
        residual = hidden_states
        hidden_states = self.final_layer_norm(hidden_states)
        hidden_states = nn.gelu(self.fc1(hidden_states))
        hidden_states = self.fc2(hidden_states)
        hidden_states = residual + hidden_states
        return hidden_states


class AudioEncoder(nn.Module):
    def __init__(self, config: AudioEncoderConfig):
        super().__init__()
        self.config = config
        embed_dim = config.d_model
        self.embed_scale = math.sqrt(embed_dim) if config.scale_embedding else 1.0
        self.n_window = config.n_window
        self.n_window_infer = config.n_window_infer
        self.conv2d1 = nn.Conv2d(
            1, config.downsample_hidden_size, kernel_size=3, stride=2, padding=1
        )
        self.conv2d2 = nn.Conv2d(
            config.downsample_hidden_size,
            config.downsample_hidden_size,
            kernel_size=3,
            stride=2,
            padding=1,
        )
        self.conv2d3 = nn.Conv2d(
            config.downsample_hidden_size,
            config.downsample_hidden_size,
            kernel_size=3,
            stride=2,
            padding=1,
        )
        freq_after_conv = ((((config.num_mel_bins + 1) // 2) + 1) // 2 + 1) // 2
        self.conv_out = nn.Linear(
            config.downsample_hidden_size * freq_after_conv, embed_dim, bias=False
        )
        self.positional_embedding = SinusoidalPositionEmbedding(
            config.max_source_positions, embed_dim
        )
        self.layers = [AudioEncoderLayer(config) for _ in range(config.encoder_layers)]
        self.ln_post = nn.LayerNorm(embed_dim)
        self.proj1 = nn.Linear(embed_dim, embed_dim)
        self.proj2 = nn.Linear(embed_dim, config.output_dim)

    def _create_block_attention_mask(self, seq_len, cu_seqlens, dtype):
        mask = mx.full((seq_len, seq_len), -1e9, dtype=dtype)
        for i in range(len(cu_seqlens) - 1):
            start, end = cu_seqlens[i], cu_seqlens[i + 1]
            mask[start:end, start:end] = 0.0
        return mask

    def _compute_chunk_layout(self, feature_lens, chunk_size):
        chunk_counts = np.ceil(feature_lens / chunk_size).astype(np.int32)
        chunk_lengths = []
        for feat_len, num_chunks in zip(feature_lens, chunk_counts):
            feat_len = int(feat_len)
            num_chunks = int(num_chunks)
            for j in range(num_chunks):
                if j == num_chunks - 1:
                    remainder = feat_len % chunk_size
                    chunk_lengths.append(chunk_size if remainder == 0 else remainder)
                else:
                    chunk_lengths.append(chunk_size)
        return chunk_counts, np.array(chunk_lengths, dtype=np.int32)

    def _slice_feature_chunks(
        self, input_features, feature_lens, chunk_counts, chunk_size
    ):
        chunks = []
        for feat, feat_len, num_chunks in zip(
            input_features, feature_lens, chunk_counts
        ):
            feat_len = int(feat_len)
            num_chunks = int(num_chunks)
            pos = 0
            remainder = feat_len % chunk_size
            for j in range(num_chunks):
                clen = (
                    chunk_size if (j < num_chunks - 1 or remainder == 0) else remainder
                )
                chunks.append(feat[:, pos : pos + clen])
                pos += clen
        return chunks

    def _pad_chunks(self, chunks, chunk_lengths):
        max_chunk_len = int(chunk_lengths.max())
        padded_chunks = []
        for chunk, clen in zip(chunks, chunk_lengths):
            clen = int(clen)
            if clen < max_chunk_len:
                chunk = mx.pad(chunk, [(0, 0), (0, max_chunk_len - clen)])
            padded_chunks.append(chunk)
        return mx.stack(padded_chunks, axis=0), max_chunk_len

    def _build_cu_seqlens(self, aftercnn_lens, window_aftercnn):
        cu_chunk_lens = [0]
        for cnn_len in aftercnn_lens:
            cnn_len = int(cnn_len)
            full_windows = cnn_len // window_aftercnn
            if full_windows:
                cu_chunk_lens.extend([window_aftercnn] * full_windows)
            remainder = cnn_len % window_aftercnn
            if remainder:
                cu_chunk_lens.append(remainder)
        return np.cumsum(cu_chunk_lens).tolist()

    def __call__(self, input_features, feature_attention_mask=None):
        if feature_attention_mask is not None:
            feature_lens = feature_attention_mask.sum(axis=-1).astype(mx.int32)
        else:
            feature_lens = mx.array(
                [input_features.shape[-1]] * input_features.shape[0], dtype=mx.int32
            )

        feature_lens_np = np.array(feature_lens)
        aftercnn_lens = _get_feat_extract_output_lengths(feature_lens)
        chunk_size = self.n_window * 2
        chunk_counts, chunk_lengths = self._compute_chunk_layout(
            feature_lens_np, chunk_size
        )
        chunks = self._slice_feature_chunks(
            input_features, feature_lens_np, chunk_counts, chunk_size
        )
        padded_feature, _ = self._pad_chunks(chunks, chunk_lengths)
        feature_lens_after_cnn = _get_feat_extract_output_lengths(
            mx.array(chunk_lengths)
        )
        feature_lens_after_cnn_np = np.array(feature_lens_after_cnn)
        max_len_after_cnn = int(feature_lens_after_cnn_np.max())

        x = padded_feature[:, :, :, None]
        x = nn.gelu(self.conv2d1(x))
        x = nn.gelu(self.conv2d2(x))
        x = nn.gelu(self.conv2d3(x))

        b, f, t, c = x.shape
        x = x.transpose(0, 2, 3, 1).reshape(b, t, c * f)
        x = self.conv_out(x)
        x = x + self.positional_embedding(x.shape[1])[None, :, :]

        hidden_list = [
            x[i, : int(feature_lens_after_cnn_np[i])] for i in range(x.shape[0])
        ]
        hidden_states = mx.concatenate(hidden_list, axis=0)

        aftercnn_lens_np = np.array(aftercnn_lens)
        window_aftercnn = max_len_after_cnn * (
            self.n_window_infer // (self.n_window * 2)
        )
        cu_seqlens = self._build_cu_seqlens(aftercnn_lens_np, window_aftercnn)
        attention_mask = self._create_block_attention_mask(
            hidden_states.shape[0], cu_seqlens, hidden_states.dtype
        )
        attention_mask = attention_mask[None, None, :, :]
        hidden_states = hidden_states[None, :, :]

        for layer in self.layers:
            hidden_states = layer(hidden_states, mask=attention_mask)

        hidden_states = self.ln_post(hidden_states[0])
        hidden_states = nn.gelu(self.proj1(hidden_states))
        return self.proj2(hidden_states)


class TextAttention(nn.Module):
    def __init__(self, config: TextConfig, layer_idx: int):
        super().__init__()
        self.hidden_size = config.hidden_size
        self.num_heads = config.num_attention_heads
        self.num_kv_heads = config.num_key_value_heads
        self.head_dim = config.head_dim
        self.scale = self.head_dim**-0.5
        self.q_proj = nn.Linear(
            config.hidden_size, self.num_heads * self.head_dim, bias=False
        )
        self.k_proj = nn.Linear(
            config.hidden_size, self.num_kv_heads * self.head_dim, bias=False
        )
        self.v_proj = nn.Linear(
            config.hidden_size, self.num_kv_heads * self.head_dim, bias=False
        )
        self.o_proj = nn.Linear(
            self.num_heads * self.head_dim, config.hidden_size, bias=False
        )
        self.q_norm = nn.RMSNorm(self.head_dim, eps=config.rms_norm_eps)
        self.k_norm = nn.RMSNorm(self.head_dim, eps=config.rms_norm_eps)
        self.rope = nn.RoPE(self.head_dim, traditional=False, base=config.rope_theta)

    def __call__(self, hidden_states, cache=None):
        B, L, _ = hidden_states.shape
        queries = self.q_proj(hidden_states).reshape(
            B, L, self.num_heads, self.head_dim
        )
        keys = self.k_proj(hidden_states).reshape(
            B, L, self.num_kv_heads, self.head_dim
        )
        values = self.v_proj(hidden_states).reshape(
            B, L, self.num_kv_heads, self.head_dim
        )
        queries = self.q_norm(queries).transpose(0, 2, 1, 3)
        keys = self.k_norm(keys).transpose(0, 2, 1, 3)
        values = values.transpose(0, 2, 1, 3)
        offset = cache.offset if cache else 0
        queries = self.rope(queries, offset=offset)
        keys = self.rope(keys, offset=offset)
        if cache:
            keys, values = cache.update_and_fetch(keys, values)
        mask = create_additive_causal_mask(queries.shape[2], offset=offset).astype(
            queries.dtype
        )
        output = mx.fast.scaled_dot_product_attention(
            queries, keys, values, scale=self.scale, mask=mask
        )
        return self.o_proj(
            output.transpose(0, 2, 1, 3).reshape(B, -1, self.num_heads * self.head_dim)
        )


class TextMLP(nn.Module):
    def __init__(self, config: TextConfig):
        super().__init__()
        self.gate_proj = nn.Linear(
            config.hidden_size, config.intermediate_size, bias=False
        )
        self.up_proj = nn.Linear(
            config.hidden_size, config.intermediate_size, bias=False
        )
        self.down_proj = nn.Linear(
            config.intermediate_size, config.hidden_size, bias=False
        )

    def __call__(self, x):
        return self.down_proj(nn.silu(self.gate_proj(x)) * self.up_proj(x))


class TextDecoderLayer(nn.Module):
    def __init__(self, config: TextConfig, layer_idx: int):
        super().__init__()
        self.self_attn = TextAttention(config, layer_idx)
        self.mlp = TextMLP(config)
        self.input_layernorm = nn.RMSNorm(config.hidden_size, eps=config.rms_norm_eps)
        self.post_attention_layernorm = nn.RMSNorm(
            config.hidden_size, eps=config.rms_norm_eps
        )

    def __call__(self, hidden_states, cache=None):
        residual = hidden_states
        hidden_states = self.self_attn(self.input_layernorm(hidden_states), cache=cache)
        hidden_states = residual + hidden_states
        return hidden_states + self.mlp(self.post_attention_layernorm(hidden_states))


class TextModel(nn.Module):
    def __init__(self, config: TextConfig):
        super().__init__()
        self.embed_tokens = nn.Embedding(config.vocab_size, config.hidden_size)
        self.layers = [
            TextDecoderLayer(config, i) for i in range(config.num_hidden_layers)
        ]
        self.norm = nn.RMSNorm(config.hidden_size, eps=config.rms_norm_eps)

    def __call__(self, input_ids=None, inputs_embeds=None, cache=None):
        hidden_states = (
            inputs_embeds if inputs_embeds is not None else self.embed_tokens(input_ids)
        )
        cache = cache or [None] * len(self.layers)
        for i, layer in enumerate(self.layers):
            hidden_states = layer(hidden_states, cache=cache[i])
        return self.norm(hidden_states)


class Qwen3ASRModel(nn.Module):
    def __init__(self, config: ModelConfig):
        super().__init__()
        self.config = config
        self.audio_tower = AudioEncoder(config.audio_config)
        self.model = TextModel(config.text_config)
        self.lm_head = (
            None
            if config.text_config.tie_word_embeddings
            else nn.Linear(
                config.text_config.hidden_size,
                config.text_config.vocab_size,
                bias=False,
            )
        )

    def get_audio_features(self, input_features, feature_attention_mask=None):
        return self.audio_tower(input_features, feature_attention_mask)

    def __call__(
        self,
        input_ids,
        input_embeddings=None,
        input_features=None,
        feature_attention_mask=None,
        cache=None,
    ):
        inputs_embeds = (
            input_embeddings
            if input_embeddings is not None
            else self.model.embed_tokens(input_ids)
        )
        if input_features is not None and (
            cache is None or cache[0] is None or cache[0].offset == 0
        ):
            audio_features = self.get_audio_features(
                input_features, feature_attention_mask
            ).astype(inputs_embeds.dtype)
            audio_token_mask = input_ids == self.config.audio_token_id
            if audio_token_mask.any():
                batch_size, seq_len, hidden_dim = inputs_embeds.shape
                flat_mask_np = np.array(audio_token_mask.reshape(-1))
                audio_indices = np.nonzero(flat_mask_np)[0]
                if len(audio_indices) > 0 and audio_features.shape[0] > 0:
                    num_to_replace = min(len(audio_indices), audio_features.shape[0])
                    flat_embeds = inputs_embeds.reshape(-1, hidden_dim)
                    indices = mx.array(audio_indices[:num_to_replace])
                    replacement = (
                        mx.zeros_like(flat_embeds)
                        .at[indices]
                        .add(audio_features[:num_to_replace])
                    )
                    mask = (
                        mx.zeros((flat_embeds.shape[0],), dtype=flat_embeds.dtype)
                        .at[indices]
                        .add(1)
                    )
                    flat_embeds = mx.where(mask[:, None] > 0, replacement, flat_embeds)
                    inputs_embeds = flat_embeds.reshape(batch_size, seq_len, hidden_dim)

        hidden_states = self.model(inputs_embeds=inputs_embeds, cache=cache)
        return (
            self.model.embed_tokens.as_linear(hidden_states)
            if self.lm_head is None
            else self.lm_head(hidden_states)
        )

    @property
    def layers(self):
        return self.model.layers

    def make_cache(self):
        from mlx_lm.models.cache import KVCache

        return [KVCache() for _ in range(self.config.text_config.num_hidden_layers)]

    @staticmethod
    def sanitize(weights):
        sanitized = {}
        is_formatted = not any(k.startswith("thinker.") for k in weights.keys())
        for k, v in weights.items():
            if k.startswith("thinker."):
                k = k[len("thinker.") :]
            if k == "lm_head.weight":
                continue
            if (
                not is_formatted
                and "conv2d" in k
                and "weight" in k
                and len(v.shape) == 4
            ):
                v = v.transpose(0, 2, 3, 1)
            sanitized[k] = v
        return sanitized


# =============================================================================
# Model Loading
# =============================================================================


def load_model(model_dir: str):
    """Load model, tokenizer, and feature extractor from a local directory."""
    import transformers
    import logging as pylogging

    pylogging.getLogger("transformers").setLevel(pylogging.ERROR)
    from transformers import AutoTokenizer, WhisperFeatureExtractor

    local_path = Path(model_dir)
    if not local_path.exists():
        raise FileNotFoundError(f"Model directory not found: {model_dir}")

    with open(local_path / "config.json", encoding="utf-8") as f:
        config_dict = json.load(f)

    if "thinker_config" in config_dict:
        thinker = config_dict["thinker_config"]
        config_dict["audio_config"] = thinker.get("audio_config", {})
        config_dict["text_config"] = thinker.get("text_config", {})
        config_dict["audio_token_id"] = thinker.get("audio_token_id", 151676)

    config = ModelConfig(
        audio_config=config_dict.get("audio_config"),
        text_config=config_dict.get("text_config"),
        audio_token_id=config_dict.get("audio_token_id", 151676),
        support_languages=config_dict.get("support_languages", []),
    )

    model = Qwen3ASRModel(config)

    weight_files = glob.glob(str(local_path / "*.safetensors"))
    weights = {}
    for wf in weight_files:
        weights.update(mx.load(wf))
    weights = Qwen3ASRModel.sanitize(weights)

    quantization = config_dict.get("quantization")
    if quantization:

        def class_predicate(p, m):
            if not hasattr(m, "to_quantized"):
                return False
            if hasattr(m, "weight") and m.weight.size % 64 != 0:
                return False
            if p.startswith("audio_tower"):
                return False
            return f"{p}.scales" in weights

        nn.quantize(
            model,
            group_size=quantization["group_size"],
            bits=quantization["bits"],
            class_predicate=class_predicate,
        )

    model.load_weights(list(weights.items()), strict=False)
    mx.eval(model.parameters())
    model.eval()

    prev_verbosity = transformers.logging.get_verbosity()
    transformers.logging.set_verbosity_error()
    try:
        tokenizer = AutoTokenizer.from_pretrained(
            str(local_path), trust_remote_code=True
        )
        feature_extractor = WhisperFeatureExtractor.from_pretrained(str(local_path))
    finally:
        transformers.logging.set_verbosity(prev_verbosity)

    return model, tokenizer, feature_extractor, config


# =============================================================================
# Transcription
# =============================================================================


def transcribe_audio(
    model, tokenizer, feature_extractor, audio_np, language="English", max_tokens=8192
):
    """Transcribe audio samples (float32 numpy array, 16kHz) to text."""
    from mlx_lm.generate import generate_step

    audio_inputs = feature_extractor(
        audio_np,
        sampling_rate=16000,
        return_attention_mask=True,
        truncation=False,
        padding=True,
        return_tensors="np",
    )
    input_features = mx.array(audio_inputs["input_features"])
    feature_attention_mask = mx.array(audio_inputs["attention_mask"])

    audio_lengths = feature_attention_mask.sum(axis=-1)
    aftercnn_lens = _get_feat_extract_output_lengths(audio_lengths)
    num_audio_tokens = int(aftercnn_lens[0].item())

    # Match supported language names
    supported = model.config.support_languages or []
    supported_lower = {lang.lower(): lang for lang in supported}
    lang_name = supported_lower.get(language.lower(), language)

    prompt = (
        f"<|im_start|>system\n<|im_end|>\n"
        f"<|im_start|>user\n<|audio_start|>{'<|audio_pad|>' * num_audio_tokens}<|audio_end|><|im_end|>\n"
        f"<|im_start|>assistant\nlanguage {lang_name}<asr_text>"
    )
    input_ids = mx.array(tokenizer.encode(prompt, return_tensors="np"))

    # Compute audio features and replace audio pad tokens
    audio_features = model.get_audio_features(input_features, feature_attention_mask)
    mx.eval(audio_features)

    inputs_embeds = model.model.embed_tokens(input_ids)
    audio_features = audio_features.astype(inputs_embeds.dtype)
    audio_token_mask = input_ids == model.config.audio_token_id

    if audio_token_mask.any():
        batch_size, seq_len, hidden_dim = inputs_embeds.shape
        flat_mask_np = np.array(audio_token_mask.reshape(-1))
        audio_indices = np.nonzero(flat_mask_np)[0]
        if len(audio_indices) > 0:
            num_to_replace = min(len(audio_indices), audio_features.shape[0])
            flat_embeds = inputs_embeds.reshape(-1, hidden_dim)
            indices = mx.array(audio_indices[:num_to_replace])
            replacement = (
                mx.zeros_like(flat_embeds)
                .at[indices]
                .add(audio_features[:num_to_replace])
            )
            mask = (
                mx.zeros((flat_embeds.shape[0],), dtype=flat_embeds.dtype)
                .at[indices]
                .add(1)
            )
            flat_embeds = mx.where(mask[:, None] > 0, replacement, flat_embeds)
            inputs_embeds = flat_embeds.reshape(batch_size, seq_len, hidden_dim)

    mx.eval(inputs_embeds)
    input_embeddings = inputs_embeds[0]
    prompt_ids = input_ids[0] if input_ids.ndim > 1 else input_ids

    eos_token_ids = [151645, 151643]
    parts = []
    for token, _ in generate_step(
        prompt=prompt_ids,
        input_embeddings=input_embeddings,
        model=model,
        max_tokens=max_tokens,
    ):
        if token in eos_token_ids:
            break
        parts.append(tokenizer.decode([int(token)]))

    return "".join(parts).strip()


# =============================================================================
# WAV file loading
# =============================================================================


def load_wav(path: str) -> np.ndarray:
    """Load a 16kHz mono 16-bit PCM WAV file and return float32 samples."""
    import wave

    with wave.open(path, "rb") as wf:
        assert wf.getnchannels() == 1, (
            f"Expected mono, got {wf.getnchannels()} channels"
        )
        assert wf.getsampwidth() == 2, (
            f"Expected 16-bit, got {wf.getsampwidth() * 8}-bit"
        )
        assert wf.getframerate() == 16000, f"Expected 16kHz, got {wf.getframerate()}Hz"
        frames = wf.readframes(wf.getnframes())
    samples = np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0
    return samples


# =============================================================================
# Main: persistent server loop
# =============================================================================


def log(msg: str):
    """Log to stderr so it doesn't interfere with the JSON protocol on stdout."""
    print(msg, file=sys.stderr, flush=True)


def main():
    parser = argparse.ArgumentParser(description="Qwen3-ASR transcription server")
    parser.add_argument(
        "--model-dir", required=True, help="Path to model weights directory"
    )
    parser.add_argument(
        "--warmup", action="store_true", help="Run a warmup transcription on startup"
    )
    args = parser.parse_args()

    log(f"[transcribe.py] Loading model from {args.model_dir}...")
    t0 = time.time()
    model, tokenizer, feature_extractor, config = load_model(args.model_dir)
    load_time = time.time() - t0
    log(f"[transcribe.py] Model loaded in {load_time:.1f}s")

    if args.warmup:
        log("[transcribe.py] Running warmup transcription...")
        t0 = time.time()
        # Generate 1 second of silence for warmup
        silence = np.zeros(16000, dtype=np.float32)
        _ = transcribe_audio(model, tokenizer, feature_extractor, silence, "English")
        warmup_time = time.time() - t0
        log(f"[transcribe.py] Warmup completed in {warmup_time:.1f}s")

    # Signal ready
    print(json.dumps({"status": "ready"}), flush=True)
    log("[transcribe.py] Ready, waiting for requests on stdin...")

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        try:
            request = json.loads(line)
        except json.JSONDecodeError as e:
            print(json.dumps({"error": f"Invalid JSON: {e}"}), flush=True)
            continue

        # Handle commands
        if "cmd" in request:
            cmd = request["cmd"]
            if cmd == "ping":
                print(json.dumps({"status": "ready"}), flush=True)
                continue
            elif cmd == "quit":
                log("[transcribe.py] Quit command received, exiting.")
                break
            else:
                print(json.dumps({"error": f"Unknown command: {cmd}"}), flush=True)
                continue

        # Handle transcription request
        wav_path = request.get("wav")
        language = request.get("language", "English")

        if not wav_path:
            print(json.dumps({"error": "Missing 'wav' field"}), flush=True)
            continue

        try:
            t0 = time.time()
            audio = load_wav(wav_path)
            duration = len(audio) / 16000.0
            log(f"[transcribe.py] Transcribing {wav_path} ({duration:.1f}s audio)...")

            text = transcribe_audio(
                model, tokenizer, feature_extractor, audio, language
            )
            elapsed = time.time() - t0
            log(
                f"[transcribe.py] Transcription completed in {elapsed:.2f}s: {text[:80]}..."
            )

            print(json.dumps({"text": text}), flush=True)
        except Exception as e:
            log(f"[transcribe.py] Error: {e}")
            print(json.dumps({"error": str(e)}), flush=True)


if __name__ == "__main__":
    main()
