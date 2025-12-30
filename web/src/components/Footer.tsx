import { Github, Twitter } from "lucide-react";

const Footer = () => {
  return (
    <footer className="py-12 px-4 border-t border-border/50">
      <div className="container mx-auto">
        <div className="flex flex-col md:flex-row justify-between items-center gap-6">
          <div className="flex items-center gap-2">
            <div className="w-8 h-8 rounded-lg bg-gradient-accent flex items-center justify-center">
              <span className="text-lg font-bold text-background">L</span>
            </div>
            <span className="text-xl font-bold">LocalWhisper</span>
          </div>

          <div className="flex items-center gap-6">
            <a
              href="https://github.com/nicorosaless/LocalWhisper"
              target="_blank"
              rel="noopener noreferrer"
              className="text-muted-foreground hover:text-primary transition-colors"
              aria-label="GitHub"
            >
              <Github className="w-5 h-5" />
            </a>
          </div>

          <p className="text-sm text-muted-foreground">
            © 2025 LocalWhisper. All rights reserved.
          </p>
        </div>
      </div>
    </footer>
  );
};

export default Footer;
