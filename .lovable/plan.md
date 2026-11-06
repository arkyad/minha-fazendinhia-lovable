# Proposta técnica revisada — Banco de dados do MVP

Nada será executado até sua autorização final. Sem telas, sem dados fictícios, sem senhas em tabelas próprias.

## Alterações em relação à versão anterior

| # | Tema | O que mudou |
|---|---|---|
| 1 | Status | Novo enum: `awaiting_contact` (inicial), `received`, `accepted`, `rejected`, `completed`, `cancelled` |
| 2 | Estoque | Removido o campo e a baixa de estoque; fica só `is_active` no produto |
| 3 | Clientes | Isolados por propriedade; o admin passa a ter leitura para suporte; o produtor só lê, sem editar |
| 4 | Idempotência | `orders.idempotency_key` (UNIQUE); repetir a chamada devolve o mesmo pedido |
| 5 | Anti-spam | Limitação configurável em tabela de parâmetros, sem números fixos no código |
| 6 | Exclusão | Pedidos e itens nunca são excluídos; propriedades e produtos com histórico são só desativados |
| 7 | Categorias | Globais; escrita exclusiva do admin |
| 8 | Proteção | O produtor não tem UPDATE/DELETE em pedidos, itens ou clientes; o status muda só pela função |
| 9 | Storage | Mantido; gestão só pelo dono da propriedade ou admin |

## 1. Relacionamentos

```text
auth.users 1─1 profiles            (CASCADE)
auth.users 1─N user_roles          (CASCADE)
profiles   1─N properties          (RESTRICT)
properties 1─N property_images     (CASCADE)
properties 1─N products            (RESTRICT)
categories 1─N products            (RESTRICT)
products   1─N product_images      (CASCADE)
properties 1─N customers           (RESTRICT)
properties 1─N orders              (RESTRICT)  cada pedido = 1 propriedade
customers  1─N orders              (RESTRICT)
orders     1─N order_items         (RESTRICT)  pedidos nunca são apagados
products   1─N order_items         (RESTRICT)
orders     1─N order_status_history(RESTRICT)
```

Consistência garantida por FK composta: `orders(customer_id, property_id)` aponta para `customers(id, property_id)`, impedindo que um pedido use um cliente de outra propriedade.

## 2. Tabelas

Todas usam `id uuid` como PK e têm `created_at`. As editáveis têm também `updated_at`, mantido por gatilho.

| Tabela | Colunas principais |
|---|---|
| profiles | id = auth.users.id, full_name, phone |
| user_roles | user_id, role (`admin`, `producer`), UNIQUE(user_id, role) |
| categories | name, slug UNIQUE, is_active, sort_order |
| properties | owner_id, name, slug UNIQUE, description, city, state, whatsapp, is_active |
| property_images | property_id, storage_path, sort_order, is_cover (máx. 1 capa: índice único parcial) |
| products | property_id, category_id, name, description, unit, price numeric(12,2) ≥ 0, is_active |
| product_images | product_id, storage_path, sort_order |
| customers | property_id, name, phone (normalizado), address, UNIQUE(property_id, phone) |
| orders | property_id, customer_id, code UNIQUE, idempotency_key UNIQUE, status, subtotal, total, notes, customer_snapshot (jsonb) |
| order_items | order_id, product_id, product_name, unit_price, quantity > 0, line_total |
| order_status_history | order_id, from_status, to_status, changed_by (nulo = sistema), note |
| order_rate_limits *(nova)* | chave (ex.: telefone+propriedade), janela, contador. Uso interno |
| app_settings *(nova)* | parâmetros configuráveis (janelas e limites anti-spam). Só o admin altera |

O `customer_snapshot` congela nome, telefone e endereço do momento do pedido, preservando o histórico mesmo que o cadastro do cliente seja atualizado em pedidos futuros.

## 3. Segurança (RLS)

Funções auxiliares `SECURITY DEFINER`: `has_role(uid, role)` e `owns_property(uid, property_id)`.

| Tabela | Visitante | Produtor | Admin |
|---|---|---|---|
| profiles | — | lê/edita o próprio | lê tudo |
| user_roles | — | lê os próprios | gerencia |
| categories | lê as ativas | lê | CRUD |
| properties | lê as ativas | lê/cria/edita as próprias (sem DELETE; desativa) | tudo |
| property_images, product_images | lê (se ativo) | CRUD nas próprias | tudo |
| products | lê os ativos de propriedades ativas | cria/edita os próprios (sem DELETE) | tudo |
| customers | — | **só leitura** (próprias propriedades) | leitura |
| orders, order_items, order_status_history | — | **só leitura** (próprias propriedades) | leitura |
| order_rate_limits | — | — | — (só pelas funções) |
| app_settings | — | — | lê/edita |

- Ninguém tem INSERT, UPDATE ou DELETE direto em pedidos, itens, histórico ou clientes; só as funções gravam.
- A exclusão de produto e propriedade é bloqueada para todos via RLS. Gatilho extra: se houver itens de pedido ligados, a exclusão é impedida mesmo para o admin (desativar).
- Gatilhos impedem a troca de `owner_id` (exceto admin) e a troca de `property_id` em produtos.

## 4. Autenticação (preparada, não habilitada)

- E-mail e senha para produtores e admins, ativado só com sua autorização.
- No cadastro, um gatilho cria o `profile` e o papel `producer`.
- O papel `admin` é atribuído apenas manualmente.
- Recomendado: verificação de senhas vazadas e confirmação de e-mail.

## 5. Pedido público — `place_order(...)`

Função `SECURITY DEFINER` executável por visitantes. Recebe `idempotency_key` (UUID gerado pelo navegador por tentativa de pedido), property_id, dados do cliente e `[{product_id, quantity}]`.

Fluxo, todo dentro de uma única transação:
1. **Idempotência**: se a chave já existir, retorna o mesmo pedido (código, total, WhatsApp) sem gravar nada novo. Se a mesma chave chegar com outro conteúdo, devolve erro.
2. **Limitação**: consulta `app_settings` e incrementa `order_rate_limits`; se exceder, retorna erro específico.
3. Valida que a propriedade existe e está ativa.
4. Valida os itens: lista não vazia, sem duplicados, quantidade inteira positiva e tetos lidos de `app_settings`.
5. Cada produto precisa estar ativo e pertencer à mesma propriedade.
6. Preços sempre do banco; qualquer preço enviado é ignorado.
7. Valida nome e telefone (obrigatórios, normalizados, com tamanho máximo).
8. Faz upsert do cliente por (propriedade, telefone), grava pedido, itens e snapshot, e registra o histórico inicial `awaiting_contact`.
9. Retorna só `code`, `total` e o WhatsApp da propriedade, para o redirecionamento.

Ordem garantida: o pedido é gravado e confirmado **antes** de a interface abrir o WhatsApp.

## 6. Mudança de status — `update_order_status(order_id, new_status, note)`

- Permitida só ao dono da propriedade ou a um admin.
- Transições válidas:

```text
awaiting_contact → received | cancelled
received         → accepted | rejected | cancelled
accepted         → completed | cancelled
rejected, completed, cancelled → (finais)
```

- Grava o histórico automaticamente com `changed_by = auth.uid()`.
- Um gatilho bloqueia qualquer mudança de `status` que não venha dessa função.

## 7. Anti-spam — proposta segura

O backend não tem um limitador de requisições padrão, então a proposta é uma solução própria no banco:
- **Contadores por janela de tempo** em `order_rate_limits`, por duas chaves: telefone+propriedade e propriedade (volume global).
- **Parâmetros em `app_settings`** (janela, máximo por janela, tetos de itens e quantidade), começando **desativados ou vazios**: nenhum número é definido por mim. Você define os valores, que podem ser ajustados sem nova migração.
- Limpeza de contadores antigos feita na própria função, sem tarefa agendada.
- **Limitação conhecida**: o banco não vê o IP do visitante. Limitar por IP exigiria um endpoint no servidor do app intermediando a chamada; isso pode ser feito depois sem mudar o banco.

## 8. Integridade

- Índices em todas as FKs, além de `orders(property_id, status, created_at desc)`, `products(property_id, is_active)` e `order_status_history(order_id, created_at)`.
- CHECKs em preço, quantidade, totais e tamanhos de texto; validação de slug e telefone.
- Gatilhos: itens e histórico imutáveis; em `orders`, só o `status` é mutável (e só via função); `updated_at` automático.

## 9. Storage

- Buckets `property-images` e `product-images`: leitura pública, limite de 5 MB, apenas jpeg/png/webp.
- Caminho `{property_id}/...`. Enviar, alterar e excluir só se `owns_property(auth.uid(), primeira pasta)` ou se o usuário for admin.

## 10. Riscos restantes

1. **Spam sem IP**: um atacante pode variar telefones. Mitigado pelo limite por propriedade; o limite por IP fica para uma etapa futura.
2. **Limites inativos até você definir valores**: enquanto vazios, não há proteção efetiva.
3. **Imagens públicas**: qualquer pessoa com o link vê o arquivo.
4. **Telefone como identificador do cliente**: não há verificação, então alguém pode digitar o telefone de outra pessoa. Por isso o snapshot por pedido preserva o que foi informado em cada um.
5. **Primeiro admin**: definido manualmente depois do primeiro cadastro.
6. **Chave idempotente**: depende de a interface futura gerar e reutilizar a chave a cada tentativa.

## Detalhes técnicos de execução (após autorização)

- Uma migração: enums → tabelas → GRANTs → RLS → funções auxiliares → políticas → gatilhos → funções `place_order` e `update_order_status` (com `REVOKE` de PUBLIC e `GRANT EXECUTE` a anon/authenticated).
- Buckets criados pela ferramenta de storage; políticas de `storage.objects` via migração.
- Linter e verificação de segurança ao final.
