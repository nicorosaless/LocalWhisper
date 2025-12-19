import { Card } from "@/components/ui/card";

const steps = [
  {
    number: "01",
    title: "Install Promptlo",
    description: "Quick setup with Ollama integration in minutes",
  },
  {
    number: "02",
    title: "Set Your Hotkey",
    description: "Configure your preferred keyboard shortcut",
  },
  {
    number: "03",
    title: "Optimize Anywhere",
    description: "Select text and press your hotkey to optimize instantly",
  },
];

const HowItWorks = () => {
  return (
    <section className="py-24 px-4">
      <div className="container mx-auto">
        <div className="text-center mb-16 animate-fade-in">
          <h2 className="text-4xl md:text-5xl font-bold mb-4">
            How It Works
          </h2>
          <p className="text-xl text-muted-foreground max-w-2xl mx-auto">
            Get started in three simple steps
          </p>
        </div>
        
        <div className="grid md:grid-cols-3 gap-8 max-w-5xl mx-auto">
          {steps.map((step, index) => (
            <div 
              key={index}
              className="relative animate-fade-in"
              style={{ animationDelay: `${index * 150}ms` }}
            >
              <Card className="p-8 bg-card/50 backdrop-blur-sm border-primary/10 hover:border-primary/30 transition-all duration-300 hover:shadow-lg hover:shadow-primary/20 h-full">
                <div className="text-6xl font-bold text-primary/20 mb-4">
                  {step.number}
                </div>
                <h3 className="text-2xl font-semibold mb-3">{step.title}</h3>
                <p className="text-muted-foreground">{step.description}</p>
              </Card>
              
              {index < steps.length - 1 && (
                <div className="hidden md:block absolute top-1/2 -right-4 w-8 h-0.5 bg-gradient-to-r from-primary/50 to-transparent" />
              )}
            </div>
          ))}
        </div>
      </div>
    </section>
  );
};

export default HowItWorks;
