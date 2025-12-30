#!/usr/bin/env python3
"""
WhisperMac - Local Speech-to-Text Dictation App for macOS
Similar to Wispr Flow but completely local and free.

Press Cmd+Shift+Space to start/stop recording.
Transcribes using whisper.cpp and auto-pastes at cursor.
"""

import os
import sys
import json
import wave
import tempfile
import subprocess
import threading
import time
from pathlib import Path

import rumps
import pyaudio
import pyperclip
from pynput import keyboard

# Configuration
APP_DIR = Path(__file__).parent.absolute()
CONFIG_FILE = APP_DIR / "config.json"
DEFAULT_MODEL_PATH = APP_DIR / "models" / "ggml-large-v3-turbo.bin"

# Audio settings (Whisper requires 16kHz mono)
SAMPLE_RATE = 16000
CHANNELS = 1
CHUNK_SIZE = 1024
FORMAT = pyaudio.paInt16


class WhisperDictation(rumps.App):
    """Menu bar application for speech-to-text dictation."""

    def __init__(self):
        super().__init__("🎤", quit_button=None)
        
        # Load configuration
        self.config = self.load_config()
        
        # State
        self.is_recording = False
        self.is_transcribing = False  # Prevent concurrent transcriptions
        self.transcribe_lock = threading.Lock()
        self.audio_frames = []
        self.audio_stream = None
        self.pyaudio_instance = None
        self.record_thread = None
        
        # Create menu items with stored references
        self.status_item = rumps.MenuItem("Estado: Listo", callback=None)
        
        # Menu items
        self.menu = [
            self.status_item,
            None,  # Separator
            rumps.MenuItem("Modelo: " + self.config.get("model", "large-v3-turbo"), callback=None),
            rumps.MenuItem("Hotkey: ⌘⇧Space (mantener)", callback=None),
            None,  # Separator
            rumps.MenuItem("Salir", callback=self.quit_app),
        ]
        
        # Start hotkey listener
        self.start_hotkey_listener()
        
        print("WhisperMac iniciado. Mantén Cmd+Shift+Space para dictar (push-to-talk).")

    def load_config(self):
        """Load configuration from JSON file."""
        if CONFIG_FILE.exists():
            with open(CONFIG_FILE, "r") as f:
                return json.load(f)
        return {
            "model": "large-v3-turbo",
            "language": "auto",
            "hotkey": "cmd+shift+space",
            "auto_paste": True,
            "model_path": str(DEFAULT_MODEL_PATH)
        }

    def start_hotkey_listener(self):
        """Start listening for global hotkey (push-to-talk)."""
        # Track pressed keys
        self.pressed_keys = set()
        self.pending_action = None  # 'start' or 'stop'
        
        def on_press(key):
            self.pressed_keys.add(key)
            # Check for Cmd+Shift+Space - start recording
            if (keyboard.Key.cmd in self.pressed_keys and 
                keyboard.Key.shift in self.pressed_keys and
                keyboard.Key.space in self.pressed_keys):
                if not self.is_recording and self.pending_action != 'start':
                    self.pending_action = 'start'
        
        def on_release(key):
            self.pressed_keys.discard(key)
            # Stop recording when any hotkey component is released
            if self.is_recording:
                if key in (keyboard.Key.cmd, keyboard.Key.shift, keyboard.Key.space):
                    self.pending_action = 'stop'
        
        listener = keyboard.Listener(on_press=on_press, on_release=on_release)
        listener.daemon = True
        listener.start()
        
        # Use rumps timer to check for pending actions (thread-safe)
        @rumps.timer(0.05)  # Check every 50ms
        def check_pending_action(sender):
            if self.pending_action == 'start':
                self.pending_action = None
                self.start_recording()
            elif self.pending_action == 'stop':
                self.pending_action = None
                self.stop_recording()

    def toggle_recording(self):
        """Toggle recording state (legacy, kept for compatibility)."""
        if self.is_recording:
            self.stop_recording()
        else:
            self.start_recording()

    def start_recording(self):
        """Start audio recording."""
        if self.is_recording:
            return
        
        # Don't start recording if transcription is in progress
        if self.transcribe_lock.locked():
            print("Transcripción en progreso, espera...")
            return
        
        self.is_recording = True
        self.audio_frames = []
        self.title = "🔴"  # Recording indicator
        self.status_item.title = "Estado: Grabando..."
        
        # Initialize PyAudio
        self.pyaudio_instance = pyaudio.PyAudio()
        
        try:
            self.audio_stream = self.pyaudio_instance.open(
                format=FORMAT,
                channels=CHANNELS,
                rate=SAMPLE_RATE,
                input=True,
                frames_per_buffer=CHUNK_SIZE
            )
            
            # Start recording in background thread
            self.record_thread = threading.Thread(target=self._record_audio)
            self.record_thread.daemon = True
            self.record_thread.start()
            
            print("Grabando...")
            
        except Exception as e:
            print(f"Error al iniciar grabación: {e}")
            self.is_recording = False
            self.title = "🎤"
            self.status_item.title = "Estado: Error"

    def _record_audio(self):
        """Record audio in background thread."""
        while self.is_recording and self.audio_stream:
            try:
                data = self.audio_stream.read(CHUNK_SIZE, exception_on_overflow=False)
                self.audio_frames.append(data)
            except Exception as e:
                print(f"Error grabando: {e}")
                break

    def stop_recording(self):
        """Stop recording and transcribe."""
        if not self.is_recording:
            return
        
        self.is_recording = False
        self.title = "⏳"  # Processing indicator
        self.status_item.title = "Estado: Transcribiendo..."
        
        # Stop audio stream
        if self.audio_stream:
            self.audio_stream.stop_stream()
            self.audio_stream.close()
            self.audio_stream = None
        
        if self.pyaudio_instance:
            self.pyaudio_instance.terminate()
            self.pyaudio_instance = None
        
        # Wait for recording thread
        if self.record_thread:
            self.record_thread.join(timeout=1.0)
        
        print(f"Grabación terminada. {len(self.audio_frames)} chunks.")
        
        # Transcribe in background
        threading.Thread(target=self._transcribe_and_paste, daemon=True).start()

    def _transcribe_and_paste(self):
        """Transcribe audio and paste result."""
        # Prevent concurrent transcriptions
        if not self.transcribe_lock.acquire(blocking=False):
            print("Transcripción en progreso, ignorando...")
            return
        
        try:
            if not self.audio_frames:
                self.title = "🎤"
                self.status_item.title = "Estado: Sin audio"
                return
            
            # Save audio to temporary WAV file
            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
                temp_wav = f.name
                
                wf = wave.open(temp_wav, 'wb')
                wf.setnchannels(CHANNELS)
                wf.setsampwidth(2)  # 16-bit
                wf.setframerate(SAMPLE_RATE)
                wf.writeframes(b''.join(self.audio_frames))
                wf.close()
            
            # Get model path
            model_path = self.config.get("model_path", str(DEFAULT_MODEL_PATH))
            if not Path(model_path).is_absolute():
                model_path = APP_DIR / model_path
            
            # Run whisper-cli with speed optimizations
            language = self.config.get("language", "auto")
            cmd = [
                "whisper-cli",
                "-m", str(model_path),
                "-f", temp_wav,
                "-nt",           # No timestamps
                "-ng",           # No GPU (avoids Metal segfault with Python)
                "-t", "8",       # 8 threads for CPU mode
                "-bs", "2",      # Beam size = 2 (balance speed/accuracy)
                "-bo", "2",      # Best of = 2
            ]
             
            if language != "auto":
                cmd.extend(["-l", language])
            
            print(f"Ejecutando: {' '.join(cmd)}")
            
            # Use Popen with Metal debug disabled to avoid crashes
            env = os.environ.copy()
            env["GGML_METAL_NDEBUG"] = "1"  # Disable Metal debug assertions
            
            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=env
            )
            stdout, stderr = proc.communicate(timeout=60)
            result_code = proc.returncode
            
            # Clean up temp file
            os.unlink(temp_wav)
            
            if result_code != 0:
                print(f"Error whisper-cpp: {stderr}")
                self.title = "❌"
                self.status_item.title = "Estado: Error"
                time.sleep(2)
                self.title = "🎤"
                self.status_item.title = "Estado: Listo"
                return
            
            # Parse output - get the transcribed text
            text = self._parse_whisper_output(stdout)
            
            if text:
                print(f"Transcripción: {text}")
                
                # Copy to clipboard
                pyperclip.copy(text)
                
                # Auto-paste if enabled
                if self.config.get("auto_paste", True):
                    time.sleep(0.1)  # Small delay for clipboard
                    self._simulate_paste()
                
                self.status_item.title = "Estado: Listo"
            else:
                print("No se detectó texto")
                self.status_item.title = "Estado: Sin texto"
            
            self.title = "🎤"
            
        except subprocess.TimeoutExpired:
            print("Timeout en transcripción")
            self.title = "❌"
            self.status_item.title = "Estado: Timeout"
        except Exception as e:
            print(f"Error en transcripción: {e}")
            self.title = "❌"
            self.status_item.title = "Estado: Error"
        finally:
            self.transcribe_lock.release()

    def _parse_whisper_output(self, output):
        """Parse whisper-cpp output to extract just the text."""
        lines = output.strip().split('\n')
        text_lines = []
        
        for line in lines:
            # Skip empty lines and metadata
            line = line.strip()
            if not line:
                continue
            # Skip lines that look like timestamps [00:00:00.000 --> 00:00:05.000]
            if line.startswith('[') and '-->' in line:
                # Extract text after the timestamp
                parts = line.split(']', 1)
                if len(parts) > 1:
                    text_lines.append(parts[1].strip())
            elif not line.startswith('whisper_') and not line.startswith('main:'):
                # Regular text line
                text_lines.append(line)
        
        return ' '.join(text_lines).strip()

    def _simulate_paste(self):
        """Simulate Cmd+V to paste using AppleScript (more reliable)."""
        try:
            # Use AppleScript instead of pynput to avoid conflicts with listener
            script = 'tell application "System Events" to keystroke "v" using command down'
            subprocess.run(["osascript", "-e", script], capture_output=True, timeout=2)
        except Exception as e:
            print(f"Error al pegar: {e}")

    def quit_app(self, _):
        """Quit the application."""
        rumps.quit_application()


def main():
    """Main entry point."""
    # Check if model exists
    if not DEFAULT_MODEL_PATH.exists():
        print(f"⚠️  Modelo no encontrado: {DEFAULT_MODEL_PATH}")
        print("Descargando modelo... esto puede tardar unos minutos.")
        print("O descárgalo manualmente de: https://huggingface.co/ggerganov/whisper.cpp")
    
    # Check whisper-cli is installed
    try:
        result = subprocess.run(["whisper-cli", "--help"], capture_output=True)
    except FileNotFoundError:
        print("❌ whisper-cli no está instalado.")
        print("Instálalo con: brew install whisper-cpp")
        sys.exit(1)
    
    app = WhisperDictation()
    app.run()


if __name__ == "__main__":
    main()
