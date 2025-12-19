import { Button } from "@/components/ui/button";
import { Download } from "lucide-react";

const CTA = () => {
  return (
    <section className="py-24 px-4 relative overflow-hidden">
      <div className="absolute inset-0 bg-gradient-primary opacity-10" />
      <div className="absolute inset-0 bg-gradient-to-t from-background via-transparent to-background" />
      
      <div className="container mx-auto text-center relative z-10">
        <div className="max-w-3xl mx-auto animate-fade-in">
          <h2 className="text-4xl md:text-5xl font-bold mb-6">
            Ready to Transform Your Workflow?
          </h2>
          <p className="text-xl text-muted-foreground mb-10">
            Join developers and writers who are optimizing prompts faster than ever
          </p>
          
          <Button 
            size="lg"
            className="bg-primary hover:bg-primary/90 text-primary-foreground font-semibold px-10 py-7 text-lg rounded-xl shadow-lg hover:shadow-primary/50 transition-all"
          >
            <Download className="mr-2 w-5 h-5" />
            Download Promptlo
          </Button>
          
          <p className="text-sm text-muted-foreground mt-6">
            Free and open source • Works on macOS, Windows, and Linux
          </p>
        </div>
      </div>
    </section>
  );
};

export default CTA;
