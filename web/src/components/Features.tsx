import { Shield, Keyboard, Globe, Cpu } from "lucide-react";
import { Card } from "@/components/ui/card";

const features = [
  {
    icon: Shield,
    title: "100% Local Processing",
    description: "Your voice and text never leave your machine. Complete privacy with local models.",
  },
  {
    icon: Keyboard,
    title: "Universal Hotkey",
    description: "Activate LocalWhisper from any application with a customizable keyboard shortcut.",
  },
  {
    icon: Globe,
    title: "Works Everywhere",
    description: "Compatible with any text field in any application on your macOS system.",
  },
  {
    icon: Cpu,
    title: "Dual Engine Support",
    description: "Switch between Whisper.cpp and Qwen3-ASR for the best performance and accuracy.",
  },
];

const Features = () => {
  return (
    <section className="py-24 px-4 relative">
      <div className="absolute inset-0 bg-gradient-to-b from-background via-card/50 to-background" />
      
      <div className="container mx-auto relative z-10">
        <div className="text-center mb-16 animate-fade-in">
          <h2 className="text-4xl md:text-5xl font-bold mb-4">
            Why LocalWhisper?
          </h2>
          <p className="text-xl text-muted-foreground max-w-2xl mx-auto">
            The perfect balance of power, privacy, and convenience
          </p>
        </div>
        
        <div className="grid md:grid-cols-2 lg:grid-cols-4 gap-6">
          {features.map((feature, index) => (
            <Card 
              key={index}
              className="p-6 bg-card/50 backdrop-blur-sm border-primary/10 hover:border-primary/30 transition-all duration-300 hover:shadow-lg hover:shadow-primary/20 animate-fade-in group"
              style={{ animationDelay: `${index * 100}ms` }}
            >
              <div className="mb-4 p-3 rounded-lg bg-primary/10 w-fit group-hover:bg-primary/20 transition-colors">
                <feature.icon className="w-6 h-6 text-primary" />
              </div>
              <h3 className="text-xl font-semibold mb-2">{feature.title}</h3>
              <p className="text-muted-foreground">{feature.description}</p>
            </Card>
          ))}
        </div>
      </div>
    </section>
  );
};

export default Features;
