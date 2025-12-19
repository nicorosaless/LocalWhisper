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
            className="absolute inset-0 bg-background/80 backdrop-blur-sm"
            onClick={() => setShowModal(false)}
          />
          <div className="relative bg-background border border-border rounded-2xl max-w-lg w-full p-6 shadow-2xl animate-in fade-in zoom-in-95 duration-200 max-h-[90vh] overflow-y-auto">
            <button
              onClick={() => setShowModal(false)}
              className="absolute top-4 right-4 text-muted-foreground hover:text-foreground transition-colors"
            >
              <X size={20} />
            </button>

            <h2 className="text-2xl font-light mb-2">Install Local Whisper</h2>
            <p className="text-sm text-muted-foreground mb-6">
              Follow these steps to install the app
            </p>

            {/* Security Warning Box */}
            <div className="bg-amber-500/10 border border-amber-500/30 rounded-lg p-4">
              <p className="text-sm font-medium text-amber-200 mb-3">
                ⚠️ Easy Install (Copy & Paste in Terminal)
              </p>

              <div className="space-y-4 text-sm text-muted-foreground">
                <div className="flex items-start gap-3">
                  <span className="bg-foreground text-background w-6 h-6 rounded-full flex items-center justify-center text-xs shrink-0 font-medium">1</span>
                  <div className="w-full">
                    <p className="font-medium text-foreground mb-2">Download the app</p>
                    <a
                      href="/LocalWhisper.dmg"
                      download="LocalWhisper.dmg"
                      className="flex items-center justify-center w-full bg-foreground text-background hover:opacity-90 font-light py-2 rounded-md text-sm transition-opacity mb-2"
                    >
                      <Download size={14} className="mr-2" />
                      Download .DMG
                    </a>
                  </div>
                </div>

                <div className="flex items-start gap-3">
                  <span className="bg-foreground text-background w-6 h-6 rounded-full flex items-center justify-center text-xs shrink-0 font-medium">2</span>
                  <div className="w-full">
                    <p className="font-medium text-foreground">Install & Open (paste in Terminal)</p>
                    <p className="text-xs text-muted-foreground/80 mt-1 mb-2">Open Terminal (Cmd+Space, type "Terminal") and paste:</p>
                    <code className="block bg-black/50 text-green-400 p-2 rounded text-xs font-mono select-all break-all">
                      hdiutil attach ~/Downloads/LocalWhisper.dmg -quiet && cp -R "/Volumes/Local Whisper Installer/Local Whisper.app" /Applications/ && hdiutil detach "/Volumes/Local Whisper Installer" -quiet && xattr -cr "/Applications/Local Whisper.app" && open "/Applications/Local Whisper.app"
                    </code>
                  </div>
                </div>
              </div>

              <p className="text-xs text-muted-foreground/70 mt-4 pt-3 border-t border-amber-500/20">
                After this, the app will live in your menu bar (look for the waveform icon ⏦).
              </p>
            </div>

            <p className="text-xs text-center text-muted-foreground/60 mt-6">
              100% open source •
              <a href="https://github.com/nicorosaless/whipermac" className="underline hover:text-foreground ml-1" target="_blank">
                View on GitHub
              </a>
            </p>
          </div>
        </div>
      )}
    </>
  );
};

export default Hero;

