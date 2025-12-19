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
            <div className="flex justify-center mb-6">
              <img src="/icon.png" alt="Local Whisper Logo" className="w-24 h-24" />
            </div>
            <h1 className="text-6xl md:text-8xl font-light tracking-tight lowercase">
              local whisper
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
              className="border-2 border-foreground hover:bg-foreground hover:text-background font-light px-12 py-6 text-lg transition-all duration-300 min-w-[200px]"
              onClick={() => setShowModal(true)}
            >
              install
            </Button>

            <Button
              size="lg"
              variant="ghost"
              className="font-light px-12 py-6 text-lg transition-all duration-300 min-w-[200px]"
              onClick={() => window.open('https://github.com/nicorosaless/whipermac', '_blank')}
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

            <div className="mb-8">
              <h2 className="text-3xl font-light tracking-tight mb-2">Install Local Whisper</h2>
              <p className="text-muted-foreground font-light">
                Choose your preferred installation method for macOS
              </p>
            </div>

            <div className="grid grid-cols-1 gap-8">
              {/* Manual Path - Centered and Expanded */}
              <div className="space-y-6">
                <div>
                  <h3 className="text-sm font-medium uppercase tracking-wider text-muted-foreground mb-4 text-center">Manual Installation</h3>
                  <div className="space-y-6 max-w-lg mx-auto">
                    <div className="flex gap-4 p-4 rounded-xl bg-muted/20 border border-border/50">
                      <span className="flex-shrink-0 w-8 h-8 rounded-full bg-primary/10 text-primary flex items-center justify-center text-sm font-bold border border-primary/20">1</span>
                      <div className="space-y-3 w-full">
                        <p className="text-base font-medium">Download the app</p>
                        <a
                          href="/LocalWhisper.dmg"
                          download="LocalWhisper.dmg"
                          className="flex items-center justify-center w-full bg-foreground text-background hover:opacity-90 font-medium py-3 rounded-xl text-sm transition-all shadow-sm hover:shadow-md"
                        >
                          <Download size={18} className="mr-2" />
                          LocalWhisper.dmg
                        </a>
                      </div>
                    </div>

                    <div className="flex gap-4 p-4 rounded-xl bg-muted/20 border border-border/50">
                      <span className="flex-shrink-0 w-8 h-8 rounded-full bg-primary/10 text-primary flex items-center justify-center text-sm font-bold border border-primary/20">2</span>
                      <div className="space-y-1">
                        <p className="text-base font-medium">Drag to Applications</p>
                        <p className="text-sm text-muted-foreground leading-relaxed">Open the .dmg and drag Local Whisper to your Applications folder.</p>
                      </div>
                    </div>

                    <div className="flex gap-4 p-4 rounded-xl bg-amber-500/5 border border-amber-500/20">
                      <span className="flex-shrink-0 w-8 h-8 rounded-full bg-amber-500/10 text-amber-600 flex items-center justify-center text-sm font-bold border border-amber-500/20">3</span>
                      <div className="space-y-2">
                        <p className="text-base font-medium text-amber-600">Security Bypass Is Required</p>
                        <p className="text-sm text-muted-foreground leading-relaxed">macOS will block the app initially. You MUST do this:</p>
                        <ul className="text-sm text-muted-foreground space-y-2 ml-1 border-l-2 border-amber-500/20 pl-4 pt-1 mt-2">
                          <li className="flex items-center gap-2"><span className="w-1.5 h-1.5 rounded-full bg-amber-500"></span>Try to open the app (it will fail)</li>
                          <li className="flex items-center gap-2"><span className="w-1.5 h-1.5 rounded-full bg-amber-500"></span>Go to <strong>System Settings</strong></li>
                          <li className="flex items-center gap-2"><span className="w-1.5 h-1.5 rounded-full bg-amber-500"></span>Open <strong>Privacy & Security</strong></li>
                          <li className="flex items-center gap-2"><span className="w-1.5 h-1.5 rounded-full bg-amber-500"></span>Scroll down and click <strong>"Open Anyway"</strong></li>
                        </ul>
                      </div>
                    </div>
                  </div>


                  <div className="mt-8 pt-6 border-t border-border/50 flex flex-col items-center gap-4">
                    <p className="text-xs text-muted-foreground/80 font-light flex items-center gap-2">
                      <span className="w-1.5 h-1.5 rounded-full bg-foreground/20" />
                      Look for the waveform icon <span className="font-sans">⏦</span> in your menu bar.
                    </p>
                    <div className="flex items-center gap-4 text-[10px] uppercase tracking-[0.2em] text-muted-foreground/40">
                      <span>Free</span>
                      <span className="w-1 h-1 rounded-full bg-current" />
                      <span>Open Source</span>
                      <span className="w-1 h-1 rounded-full bg-current" />
                      <span>100% Private</span>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      )}
    </>
  );
};

export default Hero;

