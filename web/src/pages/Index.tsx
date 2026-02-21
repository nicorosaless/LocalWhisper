import Hero from "@/components/Hero";
import Features from "@/components/Features";
import HowItWorks from "@/components/HowItWorks";
import CTA from "@/components/CTA";
import Footer from "@/components/Footer";
import { useState } from "react";

const Index = () => {
  const [showModal, setShowModal] = useState(false);

  return (
    <div className="min-h-screen bg-background">
      <Hero showModal={showModal} setShowModal={setShowModal} />
      <HowItWorks />
      <Features />
      <CTA setShowModal={setShowModal} />
      <Footer />
    </div>
  );
};

export default Index;
