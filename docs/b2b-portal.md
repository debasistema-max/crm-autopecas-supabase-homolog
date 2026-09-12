# Portal B2B do cliente

## Objetivo e isolamento

O Portal B2B é uma aplicação separada em `b2b/`. Cada usuário autenticado é
vinculado explicitamente a um único registro de `clients` pela tabela
`customer_portal_accounts`. O navegador não recebe a chave `service_role` e não
lê diretamente as tabelas internas do CRM. Toda consulta comercial usa RPCs que
resolvem o cliente por `auth.uid()` e retornam somente campos permitidos.

Funcionários continuam usando `profiles`. Contas B2B não recebem perfil interno,
menu administrativo nem acesso às tabelas de clientes, configurações, filiais,
transportadoras ou condições de pagamento. Revogar o vínculo interrompe a sessão
comercial na próxima chamada.

## Fluxo do cliente

1. o ADMIN abre **Parceiros → Clientes → Acesso B2B**;
2. informa o contato e envia o convite para o e-mail do cliente;
3. o cliente abre o link e define a própria senha;
4. acessa `b2b/` para consultar seu cadastro, catálogo, preços, estoque,
   cotações e pedidos;
5. novas cotações e pedidos ficam vinculados ao mesmo `client_id` e ao usuário
   B2B que os criou;
6. alterações de telefone, e-mail ou endereço viram solicitação pendente. O
   ADMIN aprova ou rejeita no cadastro do cliente; a aprovação é transacional e
   auditada.

## Regras comerciais preservadas

- cliente PR usa rota PR→PR; cliente SC usa PR→SC; cliente SP usa SP→SP;
- os preços vêm de resultados aprovados do Excel em `product_route_prices`;
- estoque é o último snapshot válido persistido no Supabase;
- ausência de snapshot não é interpretada como zero;
- cotação pode ser criada sem reservar saldo;
- pedido valida o estoque no banco no momento da gravação;
- em SP→SP, falta confirmada em SP consulta o saldo transferível de PR e cria a
  solicitação PR→SP vinculada ao pedido, quando houver cobertura;
- pedidos e cotações criados internamente também recebem `client_id` por código
  SAP/CNPJ e aparecem para o respectivo cliente.

## Segurança e auditoria

- convites, revogações e reativações passam pela Edge Function `b2b-admin`, que
  exige sessão ADMIN;
- a chave privilegiada existe apenas no ambiente da Edge Function;
- `idempotency_key` impede duplicação por reenvio do navegador;
- o preço e a origem do Excel são copiados para o snapshot do item;
- criações, concessões, revogações e decisões cadastrais são registradas em
  `logs`;
- a análise cadastral usa trava de linha para impedir dupla aprovação.

## Configuração de autenticação

No Supabase Auth, a URL abaixo deve estar na lista de redirecionamentos
permitidos da homologação:

`https://debasistema-max.github.io/crm-autopecas-supabase-homolog/b2b/`

O ambiente da função aceita `B2B_REDIRECT_URL` e `B2B_ALLOWED_ORIGINS`. Na falta
deles, usa os endereços de homologação e desenvolvimento local definidos no
código.

## Diagnóstico

- **Convite não abre o portal:** conferir a URL de redirecionamento do Auth e o
  prazo do e-mail.
- **Acesso não autorizado:** conferir se o vínculo está ativo e se o cliente
  permanece ativo.
- **Preço indisponível:** conferir sincronização e aprovação da rota no Excel.
- **Estoque não importado:** executar a sincronização; não cadastrar zero para
  contornar ausência de snapshot.
- **Pedido recusado:** revisar quantidade e saldos retornados; uma cotação não
  garante reserva.
- **Documento interno não aparece:** conferir código SAP/CNPJ do documento e do
  cadastro canônico do cliente.

## Reversão operacional

O acesso pode ser revogado sem excluir usuário, documentos ou auditoria. Não há
exclusão em cascata de histórico comercial. Uma solicitação cadastral já
revisada não pode ser aplicada novamente.
