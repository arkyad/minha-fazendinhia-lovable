import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useState, type FormEvent } from "react";
import { supabase } from "@/integrations/supabase/client";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";

export const Route = createFileRoute("/auth")({
  ssr: false,
  head: () => ({
    meta: [
      { title: "Entrar — Plataforma Rural" },
      { name: "description", content: "Acesso dos produtores à Plataforma Rural." },
      { property: "og:title", content: "Entrar — Plataforma Rural" },
      { property: "og:description", content: "Acesso dos produtores à Plataforma Rural." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: AuthPage,
});

function AuthPage() {
  const navigate = useNavigate();
  const [mode, setMode] = useState<"login" | "signup">("login");
  const [name, setName] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);

  async function submit(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setMsg(null);
    if (mode === "login") {
      const { error } = await supabase.auth.signInWithPassword({ email, password });
      setBusy(false);
      if (error) return setMsg({ ok: false, text: "E-mail ou senha incorretos, ou e-mail ainda não confirmado." });
      navigate({ to: "/painel", replace: true });
    } else {
      const { error } = await supabase.auth.signUp({
        email,
        password,
        options: { emailRedirectTo: window.location.origin + "/auth", data: { full_name: name } },
      });
      setBusy(false);
      if (error) return setMsg({ ok: false, text: error.message.includes("pwned") || error.message.toLowerCase().includes("weak") ? "Essa senha é fraca ou já vazou na internet. Escolha outra." : "Não foi possível criar a conta. Verifique os dados." });
      setMsg({ ok: true, text: "Conta criada! Abra seu e-mail e clique no link de confirmação para entrar." });
      setMode("login");
    }
  }

  return (
    <main className="flex min-h-screen items-center justify-center bg-background px-4">
      <form onSubmit={submit} className="w-full max-w-sm space-y-5">
        <h1 className="text-2xl font-bold text-foreground">
          {mode === "login" ? "Entrar" : "Criar conta de produtor"}
        </h1>
        {mode === "signup" && (
          <div className="space-y-2">
            <Label htmlFor="name">Seu nome</Label>
            <Input id="name" required maxLength={120} value={name} onChange={(e) => setName(e.target.value)} className="h-12 text-base" />
          </div>
        )}
        <div className="space-y-2">
          <Label htmlFor="email">E-mail</Label>
          <Input id="email" type="email" required autoComplete="email" value={email} onChange={(e) => setEmail(e.target.value)} className="h-12 text-base" />
        </div>
        <div className="space-y-2">
          <Label htmlFor="password">Senha</Label>
          <Input id="password" type="password" required minLength={8} autoComplete={mode === "login" ? "current-password" : "new-password"} value={password} onChange={(e) => setPassword(e.target.value)} className="h-12 text-base" />
        </div>
        {msg && <p className={msg.ok ? "text-sm text-foreground" : "text-sm text-destructive"}>{msg.text}</p>}
        <Button type="submit" disabled={busy} className="h-12 w-full text-base">
          {busy ? "Aguarde..." : mode === "login" ? "Entrar" : "Criar conta"}
        </Button>
        <button type="button" onClick={() => { setMode(mode === "login" ? "signup" : "login"); setMsg(null); }} className="w-full text-sm text-muted-foreground underline">
          {mode === "login" ? "Sou produtor e ainda não tenho conta" : "Já tenho conta"}
        </button>
      </form>
    </main>
  );
}
