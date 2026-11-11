import { createFileRoute, Link } from "@tanstack/react-router";

export const Route = createFileRoute("/")({
  head: () => ({
    meta: [
      { title: "Plataforma Rural — direto de quem produz" },
      { name: "description", content: "Conectamos produtores rurais diretamente aos consumidores." },
      { property: "og:title", content: "Plataforma Rural — direto de quem produz" },
      { property: "og:description", content: "Conectamos produtores rurais diretamente aos consumidores." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: Index,
});

function Index() {
  return (
    <main className="flex min-h-screen flex-col items-center justify-center gap-6 bg-background px-4 text-center">
      <h1 className="text-3xl font-bold text-foreground">Plataforma Rural</h1>
      <p className="text-muted-foreground">Produtos direto de quem produz.</p>
      <Link to="/auth" className="rounded-md bg-primary px-6 py-3 text-base font-medium text-primary-foreground">
        Área do produtor
      </Link>
    </main>
  );
}
