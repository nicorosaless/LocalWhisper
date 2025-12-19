const Comparison = () => {
  return (
    <section className="min-h-screen flex items-center justify-center px-6 py-24">
      <div className="max-w-6xl mx-auto w-full">
        <h2 className="text-3xl md:text-5xl font-light text-center mb-16 lowercase">
          before & after
        </h2>
        
        <div className="grid md:grid-cols-2 gap-8 md:gap-12">
          <div className="space-y-4">
            <p className="text-sm uppercase tracking-wider text-muted-foreground">before</p>
            <div className="aspect-video bg-secondary border border-border flex items-center justify-center">
              <p className="text-muted-foreground font-light">video placeholder</p>
            </div>
          </div>
          
          <div className="space-y-4">
            <p className="text-sm uppercase tracking-wider text-muted-foreground">after</p>
            <div className="aspect-video bg-secondary border border-border flex items-center justify-center">
              <p className="text-muted-foreground font-light">video placeholder</p>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
};

export default Comparison;
