import { Button } from "@/components/ui/button";
import { useState } from "react";
import { X, Download } from "lucide-react";

const Hero = () => {
  const [showModal, setShowModal] = useState(false);

  return (
    <>
      <section className="min-h-screen flex items-center justify-center px-6">
        <div className="max-w-2xl mx-auto text-center space-y-12">
          <div className="space-y-2">
            <div className="flex justify-center mb-6 relative group">
              <div className="absolute inset-0 bg-[#8B5CF6]/20 blur-3xl rounded-full scale-110 opacity-50 group-hover:opacity-100 transition-opacity duration-500" />
              <img src="/icon.png" alt="LocalWhisper Logo" className="w-24 h-24 relative z-10 drop-shadow-2xl" />
            </div>
            <h1 className="text-6xl md:text-8xl font-light tracking-tight">
              Local Whisper
            </h1>
            <p className="text-sm tracking-widest uppercase text-muted-foreground font-medium">
              Only for Mac
            </p>
          </div>

          <div className="space-y-4 text-lg md:text-xl text-muted-foreground font-light">
            <p>instant voice transcription</p>
            <p>running locally on your device</p>
            <p>open source & secure</p>
          </div>

          <div className="pt-8 flex flex-col md:flex-row items-center justify-center gap-6">
            <Button
              size="lg"
              variant="outline"
              className="border-2 border-[#8B5CF6] text-[#8B5CF6] hover:bg-[#8B5CF6] hover:text-white font-light px-12 py-6 text-lg transition-all duration-300 min-w-[200px] shadow-[0_0_20px_rgba(139,92,246,0.15)] hover:shadow-[0_0_25px_rgba(139,92,246,0.3)]"
              onClick={() => setShowModal(true)}
            >
              install
            </Button>

            <Button
              size="lg"
              variant="ghost"
              className="font-light px-12 py-6 text-lg transition-all duration-300 min-w-[200px] hover:text-[#8B5CF6] hover:bg-[#8B5CF6]/5"
              onClick={() => window.open('https://github.com/nicorosaless/LocalWhisper', '_blank')}
            >
              github
            </Button>
          </div>

          <p className="text-xs text-muted-foreground/60">
            Free & open source • No account required • 100% private
          </p>
        </div>
      </section>

      {/* Installation Modal */}
      {showModal && (
        <div className="fixed inset-0 z-50 flex items-center justify-center p-4">
          <div
            className="absolute inset-0 bg-background/90 backdrop-blur-md transition-all duration-300"
            onClick={() => setShowModal(false)}
          />
          <div className="relative bg-card border border-border/50 rounded-3xl max-w-2xl w-full p-8 shadow-2xl animate-in fade-in zoom-in-95 duration-300 max-h-[90vh] overflow-y-auto">
            <button
              onClick={() => setShowModal(false)}
              className="absolute top-6 right-6 text-muted-foreground hover:text-foreground transition-colors p-2 hover:bg-muted rounded-full"
            >
              <X size={20} />
            </button>

            <div className="mb-8 text-center">
              <h2 className="text-3xl font-light tracking-tight mb-2">Install Local Whisper</h2>
              <div className="flex justify-center mt-4">
                <a
                  href="/LocalWhisper.dmg"
                  download="LocalWhisper.dmg"
                  className="flex items-center justify-center gap-3 bg-[#8B5CF6] text-white hover:bg-[#7C3AED] font-medium py-3 px-8 rounded-full text-lg transition-all shadow-lg hover:shadow-[#8B5CF6]/25"
                >
                  <Download size={20} />
                  Download for Mac
                </a>
              </div>
            </div>

            <div className="space-y-6">

              {/* Security/Open Source Explanation */}
              <div className="p-4 rounded-xl bg-blue-500/5 border border-blue-500/20 text-sm">
                <div className="flex gap-3">
                  <span className="text-blue-500 mt-0.5"><span className="w-2 h-2 rounded-full bg-blue-500 block relative top-1.5"></span></span>
                  <div className="space-y-1">
                    <p className="font-medium text-blue-600 dark:text-blue-400">Why a security warning?</p>
                    <p className="text-muted-foreground leading-relaxed">
                      This project is <strong>100% open source and free</strong>. The code is fully auditable on <a href="https://github.com/nicorosaless/LocalWhisper" target="_blank" className="underline underline-offset-2 hover:text-foreground">GitHub</a>.
                      Because we don't pay for an Annual Apple Developer ID subscription to keep this tool free, macOS treats it as an "unidentified developer". It is completely safe to run.
                    </p>
                  </div>
                </div>
              </div>

              {/* Installation Steps */}
              <div className="space-y-4">
                <h3 className="text-sm font-medium uppercase tracking-wider text-muted-foreground text-center">Installation Steps</h3>

                <div className="grid gap-4">
                  <div className="flex gap-4 p-4 rounded-xl bg-muted/20 border border-border/50 items-center">
                    <span className="flex-shrink-0 w-8 h-8 rounded-full bg-primary/10 text-primary flex items-center justify-center text-sm font-bold border border-primary/20">1</span>
                    <p className="text-base font-medium">Open the <strong>.dmg</strong> and drag to Applications</p>
                  </div>

                  <div className="flex gap-4 p-4 rounded-xl bg-amber-500/5 border border-amber-500/20">
                    <span className="flex-shrink-0 w-8 h-8 rounded-full bg-amber-500/10 text-amber-600 flex items-center justify-center text-sm font-bold border border-amber-500/20">2</span>
                    <div className="space-y-2 w-full">
                      <p className="text-base font-medium text-amber-600">First Launch</p>
                      <ul className="text-sm text-muted-foreground space-y-2">
                        <li className="flex items-center gap-2"><span className="w-1.5 h-1.5 rounded-full bg-amber-500"></span>Open the app & click <strong>"Done"</strong> if blocked</li>
                        <li className="flex items-center gap-2"><span className="w-1.5 h-1.5 rounded-full bg-amber-500"></span>Go to <strong>System Settings</strong> &gt; <strong>Privacy & Security</strong></li>
                        <li className="flex items-center gap-2"><span className="w-1.5 h-1.5 rounded-full bg-amber-500"></span>Scroll down and click <strong>"Open Anyway"</strong></li>
                      </ul>
                    </div>
                  </div>
                </div>
              </div>

              <div className="pt-4 border-t border-border/50 text-center">
                <p className="text-xs text-muted-foreground/60 italic">
                  Licensed under MIT License. You are free to use and modify, but please respect the project's attribution.
                </p>
              </div>

            </div>
          </div>
        </div>
      )}
    </>
  );
};

export default Hero;

