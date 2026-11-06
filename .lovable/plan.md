# Proposta técnica — Banco de dados do MVP (Lovable Cloud / PostgreSQL)

Nada será executado até sua autorização. Sem telas, sem dados fictícios, sem senhas em tabelas próprias: as senhas ficam só no sistema de autenticação.

## 1. Modelo conceitual

```text
auth.users 1─1 profiles (produtor/admin)
auth.users 1─N user_roles
profiles   1─N properties        (produtor é dono de N propriedades)
properties 1─N property_images
properties 1─N products
categories 1─N products          (categoria global, gerida pelo admin)
products   1─N product_images
properties 1─N customers         (cliente é escopado por propriedade)
properties 1─N orders            (cada pedido pertence a UMA propriedade)
customers  1─N orders
orders     1─N order_items  N─1 products
orders     1─N order_status_history
```

## 2. Tabelas

Toda tabela tem `id uuid PK default gen_random_uuid()`, `created_at` e, onde é editável, `updated_at` atualizado por gatilho.

| Tabela | Colunas principais | Exclusão (FK) |
|---|---|---|
| profiles | id = auth.users.id, full_name, phone, avatar_url | CASCADE quando o usuário é excluído |
| user_roles | user_id, role (enum `admin`, `producer`), UNIQUE(user_id, role) | CASCADE quando o usuário é excluído |
| categories | name, slug UNIQUE, is_active, sort_order | RESTRICT se houver produtos |
| properties | owner_id → profiles, name, slug UNIQUE, description, city, state, whatsapp, is_active | RESTRICT (desativar em vez de excluir) |
| property_images | property_id, storage_path, sort_order, is_cover | CASCADE |
| products | property_id, category_id, name, description, unit, price numeric(12,2) CHECK ≥ 0, stock_qty CHECK ≥ 0 (opcional), is_active | property: CASCADE; category: RESTRICT |
| product_images | product_id, storage_path, sort_order | CASCADE |
| customers | property_id, name, phone, email, address | RESTRICT se houver pedidos |
| orders | property_id, customer_id, code UNIQUE, status (enum), subtotal, total, notes | property/customer: RESTRICT |
| order_items | order_id, product_id, product_name (snapshot), unit_price (snapshot), quantity CHECK > 0, line_total | order: CASCADE; product: RESTRICT |
| order_status_history | order_id, from_status, to_status, changed_by (nulo = sistema), note | CASCADE |

Enum `order_status`: `pending`, `confirmed`, `preparing`, `ready`, `delivered`, `cancelled`.

## 3. Segurança (RLS)

Funções auxiliares com `SECURITY DEFINER`: `has_role(uid, role)` e `owns_property(uid, property_id)`.

| Tabela | Visitante (sem login) | Produtor | Admin |
|---|---|---|---|
| profiles | — | lê/edita o próprio perfil | lê tudo |
| user_roles | — | lê os próprios papéis | gerencia |
| categories | lê as ativas | lê | CRUD |
| properties | lê as ativas | CRUD só nas próprias | CRUD |
| property_images / products / product_images | lê o que é ativo de propriedades ativas | CRUD só nas próprias propriedades | CRUD |
| customers | **nenhum acesso** | lê/edita os clientes das próprias propriedades | lê tudo |
| orders | **nenhum acesso direto** | lê os pedidos das próprias propriedades; muda o status apenas por função | lê tudo |
| order_items | — | só leitura (das próprias propriedades) | só leitura |
| order_status_history | — | só leitura (das próprias propriedades) | só leitura |

Os visitantes nunca gravam direto nas tabelas, só pela função pública de pedido. Os acessos de leitura são liberados apenas onde as regras acima permitem.

## 4. Autenticação (preparada, não habilitada)

- E-mail e senha para produtores e administradores; o login fica desligado até você autorizar.
- Gatilho no cadastro cria o `profile` e o papel `producer`.
- O papel `admin` nunca é atribuído pelo próprio usuário: só manualmente ou por outro admin.
- Recomendação: ativar a verificação de senhas vazadas e manter a confirmação de e-mail ligada.

## 5. Pedido público — `place_order(...)`

Função `SECURITY DEFINER`, executável por `anon`, que recebe: property_id, dados do cliente (nome, telefone, endereço, observação) e itens `[{product_id, quantity}]`.

Validações, todas feitas no banco:
1. A propriedade existe e está ativa.
2. Há de 1 a 50 itens, quantidade inteira entre 1 e um teto definido, sem produtos repetidos.
3. Cada produto existe, está ativo e **pertence à mesma propriedade**.
4. O preço vem **sempre do banco**; o preço enviado pelo cliente é ignorado.
5. Se houver estoque controlado, ele é baixado com `FOR UPDATE`, sem permitir valor negativo.
6. Nome e telefone são obrigatórios, com tamanhos máximos.
7. Cliente: reaproveita pelo telefone dentro da propriedade, ou cria um novo.
8. Cria o pedido, os itens com snapshot do preço, o total e o primeiro registro de histórico (`pending`).
9. Retorna apenas o `code` e o total do pedido, nunca outros dados.

## 6. Mudança de status — `update_order_status(order_id, new_status, note)`

- Só o produtor dono da propriedade ou um admin.
- Transições válidas controladas por uma matriz (ex.: `delivered` e `cancelled` são finais).
- Grava o histórico automaticamente.

## 7. Integridade e proteção

- Índices em todas as FKs, além de `orders(property_id, status, created_at desc)`, `products(property_id, is_active)` e `customers(property_id, phone)` UNIQUE.
- CHECKs em preço, quantidade e total; tamanhos máximos em textos; validação de slug.
- Gatilhos que **impedem**:
  - editar `order_items` depois de criado;
  - alterar `property_id`, `total` ou `customer_id` de um pedido;
  - mudar `status` fora da função;
  - trocar o `owner_id` de uma propriedade (só admin);
  - editar ou apagar o histórico.
- `updated_at` atualizado automaticamente.

## 8. Armazenamento de imagens

- Dois buckets **públicos para leitura**: `property-images` e `product-images`.
- Caminho padrão: `{property_id}/{arquivo}`.
- Políticas: enviar, alterar e excluir só para o dono da propriedade (verificado pela primeira pasta do caminho) ou para admin.
- Limite de 5 MB por arquivo; apenas jpeg, png e webp.

## 9. Riscos e decisões que precisam da sua atenção

1. **Abuso do pedido público (spam)**: sem login, qualquer um pode chamar a função. Proponho um limite por telefone e por propriedade (ex.: 5 pedidos/10 min) no banco. Um captcha exigiria tela, o que fica fora desta etapa.
2. **Dados pessoais dos consumidores** (telefone, endereço): ficam visíveis só para o produtor da propriedade e para o admin. Confirme se o admin deve vê-los.
3. **Clientes escopados por propriedade**: o mesmo consumidor gera registros separados em cada propriedade. Isso garante o isolamento entre produtores. Confirme.
4. **Estoque**: controlar ou não? Se não, a coluna fica nula e nada é baixado.
5. **Imagens públicas**: qualquer arquivo enviado pode ser acessado pelo link, então não devem ser enviadas imagens sensíveis.
6. **Exclusão de propriedades e produtos com pedidos**: proponho bloquear e usar `is_active = false`, preservando o histórico.
7. **Primeiro admin**: será definido manualmente por você depois do primeiro cadastro.
8. **Categorias globais ou por propriedade?** A proposta usa globais, geridas pelo admin.
9. Cancelamento pelo consumidor não está previsto, por estar fora do escopo.

## Detalhes técnicos de execução (após autorização)

- Uma migração em ordem: enums → tabelas → GRANTs → RLS → funções auxiliares → políticas → gatilhos → funções de pedido/status.
- Buckets criados pela ferramenta de armazenamento; políticas de `storage.objects` via migração.
- Rodar o linter e a verificação de segurança ao final.
