import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { Button } from "@/components/ui/button";

export const Route = createFileRoute("/_authenticated/painel")({
  head: () => ({ meta: [{ title: "Meu painel — Plataforma Rural" }] }),
  component: Painel,
});

function Painel() {
  const { user } = Route.useRouteContext();
  const navigate = useNavigate();
  const qc = useQueryClient();
  const { data } = useQuery({
    queryKey: ["me", user.id],
    queryFn: async () => {
      const [p, r, props] = await Promise.all([
        supabase.from("profiles").select("full_name").eq("id", user.id).maybeSingle(),
        supabase.from("user_roles").select("role").eq("user_id", user.id),
        supabase.from("properties").select("id", { count: "exact", head: true }).eq("owner_id", user.id),
      ]);
      return { name: p.data?.full_name, roles: (r.data ?? []).map((x) => x.role), count: props.count ?? 0 };
    },
  });

  async function signOut() {
    await qc.cancelQueries();
    qc.clear();
    await supabase.auth.signOut();
    navigate({ to: "/auth", replace: true });
  }

  const isAdmin = data?.roles.includes("admin");
  return (
    <main className="mx-auto max-w-md space-y-4 px-4 py-10">
      <h1 className="text-2xl font-bold text-foreground">Olá, {data?.name || user.email}</h1>
      <p className="text-muted-foreground">
        Acesso: {isAdmin ? "Administrador" : "Produtor"} · Propriedades: {data?.count ?? "…"}
      </p>
      <Button onClick={signOut} variant="outline" className="h-12 w-full text-base">Sair</Button>
    </main>
  );
}
