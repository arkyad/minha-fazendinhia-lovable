# Versão final — 4 ajustes técnicos

## Aviso importante sobre o estado atual

Após a aprovação da proposta revisada, a estrutura **já foi criada no banco** na etapa anterior. Isso inclui tabelas, segurança, funções de pedido e regras de imagens; só as pastas de imagens ficaram pendentes.

Por isso, os quatro ajustes abaixo serão aplicados como **uma migração complementar** sobre o que já existe. Não há dados no banco, então nada se perde. Nada será executado sem sua autorização.

## Ajuste 1 — customers UNIQUE(id, property_id)

**Já está implementado.** A restrição `UNIQUE (id, property_id)` existe em `customers`. A chave composta `orders(customer_id, property_id) → customers(id, property_id)` já está ativa. Nenhuma mudança é necessária.

## Ajuste 2 — Status da propriedade: draft / published / suspended

- Novo tipo `property_status` com os valores `draft`, `published` e `suspended`.
- Nova coluna `properties.status`, NOT NULL, padrão `draft`.
- A coluna `is_active` deixa de ser usada e é marcada como DEPRECATED. Ela não é removida, para evitar uma mudança destrutiva. Um gatilho a mantém sincronizada (`is_active = status = 'published'`) só por compatibilidade.
- Regras, garantidas por gatilho no banco:
  - Produtor: cria a propriedade sempre como `draft` (qualquer outro valor é rejeitado). Pode editar os dados da própria propriedade, mas **não pode alterar `status`**.
  - Admin: é o único que publica, suspende ou volta a propriedade para rascunho.
- Leitura pública, pedidos e imagens passam a exigir `status = 'published'`. Isso vale para catálogo, produtos, imagens e `place_order`. Uma propriedade suspensa some do catálogo e não recebe pedidos, mas o produtor e o admin continuam vendo tudo, inclusive o histórico.
- Novo índice: `properties(status)`.

## Ajuste 3 — Sem exclusão física de propriedades e produtos

- Remover as permissões e políticas de DELETE em `properties` e `products`, inclusive para o admin.
- Gatilho `BEFORE DELETE` em `properties` e `products` que **sempre** rejeita a exclusão. Ele vale até para acessos de serviço, fechando a última porta. A operação normal será:
  - propriedade: `status = 'suspended'`;
  - produto: `is_active = false`.
- Eliminar cascatas que poderiam apagar algo ligado a pedidos:
  - `property_images.property_id` e `product_images.product_id` passam de CASCADE para RESTRICT.
  - Pedidos, itens, histórico e clientes já usam RESTRICT e já têm gatilhos de imutabilidade e de bloqueio de exclusão.
- As imagens individuais continuam podendo ser removidas pelo dono ou pelo admin. Elas não fazem parte do histórico, porque os itens do pedido guardam nome e preço próprios.
- Efeito colateral: uma conta de produtor que tenha propriedades **não pode ser excluída**, porque a exclusão do perfil é bloqueada. Para desligar um produtor, o caminho é suspender as propriedades dele e desativar o acesso.

## Ajuste 4 — Anti-spam atômico e à prova de concorrência

**Problema na versão atual:** quando um limite é atingido ou uma validação falha, a função gera um erro. Isso desfaz toda a transação, **inclusive o contador**, e as tentativas bloqueadas ou inválidas deixam de contar.

**Solução:**
1. **Contagem antes de tudo, em operação atômica.** Um único `INSERT ... ON CONFLICT DO UPDATE SET hits = hits + 1 RETURNING hits` por chave. O banco trava a linha do contador, então chamadas simultâneas são contadas uma a uma, sem perder incrementos e sem a corrida "ler e depois gravar".
2. **Contador fora da área que pode ser desfeita.** A gravação do pedido roda num bloco interno protegido (subtransação). Se qualquer validação falhar, só o pedido é desfeito; o contador permanece gravado.
3. **Erros de regra viram resposta, não exceção.** A função retorna `{ ok: false, error: 'RATE_LIMITED' | 'PRODUCT_UNAVAILABLE' | ... }`, e a transação é confirmada com o contador incluído. Pedido aceito retorna `{ ok: true, code, total, whatsapp }`.
4. **Tentativas bloqueadas continuam contando.** Assim, um ataque contínuo permanece bloqueado até a janela expirar.
5. **Ordem dentro da função:** validação básica de formato → trava pela chave idempotente → se a chave já existe, devolve o mesmo pedido (repetição legítima não conta como tentativa) → contagem nas duas chaves (telefone+propriedade e propriedade) → verificação do limite → bloco protegido de criação do pedido.
6. **Contagem inclusive de telefone inválido:** se o telefone vier malformado, conta apenas na chave da propriedade.
7. **Limpeza:** cada chamada remove as janelas expiradas da própria chave; não há tarefa agendada.
8. **Limites continuam configuráveis em `app_settings`.** Enquanto estiverem vazios, a contagem é registrada, mas nada é bloqueado.

**Limitação que permanece:** o banco não vê o IP. A contagem por IP exige um intermediário no servidor do app, previsto para uma etapa futura.

## Pendências que seguem em aberto

- **Pastas de imagens:** o workspace bloqueia pastas públicas. A decisão é sua: liberar em Settings → Privacy & Security ou usar pastas privadas com links temporários.
- Valores anti-spam, primeiro admin e ativação do login dependem de você.

## Detalhes técnicos (após autorização)

Uma migração complementar, nesta ordem:
1. Enum `property_status`, coluna `status`, comentário DEPRECATED em `is_active`.
2. Gatilhos `guard_property_status` (insert como draft, alteração de status só por admin) e de sincronização de `is_active`.
3. Recriar `is_public_property` e as políticas de leitura usando `status = 'published'`.
4. `DROP POLICY` dos DELETE em properties/products, `REVOKE DELETE` desses dois para authenticated, e gatilhos `block_delete`.
5. Trocar as FKs das imagens para RESTRICT.
6. Reescrever `place_order` com contagem atômica antes de tudo, bloco interno com EXCEPTION e retorno estruturado `ok/error`.
7. Rodar o linter e testar no banco: pedido válido, repetição idempotente, limite atingido com chamadas sequenciais, e confirmação de que o contador persiste após rejeição.
