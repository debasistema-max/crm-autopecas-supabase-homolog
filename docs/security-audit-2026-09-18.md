# Auditoria de segurança — homologação — 18/09/2026

## Escopo

Auditoria do CRM interno, Portal B2B, cadastro público, Supabase/PostgreSQL,
Edge Functions, sincronização Excel, frontend estático e repositório GitHub.
Produção não foi alterada.

## Resultado

- Todas as tabelas expostas do schema `public` permanecem com RLS ativo.
- A role anônima não possui mais acesso direto a nenhuma tabela operacional.
- Antes do login, somente `resolve_login_email` e
  `get_public_company_identity` podem ser executadas.
- As duas contas B2B existentes estão vinculadas a um único cliente cada,
  sem perfil interno e sem divergência nos metadados de autenticação.
- B2B continua acessando catálogo e documentos exclusivamente por RPCs
  próprias, com validação de `auth.uid()`, cliente, rota e permissões.
- Helpers fiscais, valores internos de sincronização e enumeração de códigos
  não podem mais ser chamados diretamente por uma conta B2B.
- A troca obrigatória da senha inicial deixou de depender de uma confirmação
  feita pelo navegador. A senha é alterada no servidor e só então a conta é
  ativada.
- Senhas novas exigem 12 a 72 caracteres, maiúscula, minúscula e número.
- `service_role`, segredos do agendador, token Graph e senhas SMTP continuam
  somente no servidor/armazenamento de secrets; nenhum deles foi encontrado
  no frontend ou no histórico analisado.
- `consulta-cnpj` e `cadastro-cliente`, que estavam apenas implantadas no
  Supabase, agora estão versionadas no GitHub.
- Cadastro público não grava mais diretamente no banco. A Edge Function usa
  lista permitida de campos, limites de tamanho, validação real do base64,
  e-mail estrito, remoção de quebras em cabeçalhos e rate limit sem armazenar
  IP em claro.
- Edge Functions bloqueiam origens web não autorizadas e devolvem respostas
  com `no-store` e `nosniff`.
- Supabase JS foi fixado em `2.116.0` e protegido por SRI SHA-384. As páginas
  receberam CSP e política `no-referrer`.
- O CRM não grava mais seu espelho de perfil/sessão no `sessionStorage`;
  mantém somente os campos necessários em memória e deixa a credencial sob
  gestão do cliente oficial do Supabase Auth.
- O leitor local de Excel foi atualizado do SheetJS `0.18.5` para `0.20.3`,
  corrigindo CVE-2023-30533 e CVE-2024-22363. O arquivo oficial foi
  vendorizado no projeto e seu SHA-256 é verificado pelos testes:
  `cc015130aa8521e7f088f88898eba949ccdcbfb38df0bd129b44b7273c3a6f41`.
- GitHub Actions passou a ter CodeQL semanal/em push e regressão de segurança.
  Dependabot foi configurado para Actions e Python.
- A varredura CodeQL final ficou com zero alertas abertos; quatro achados
  iniciais foram corrigidos. Dependabot e secret scanning também ficaram sem
  alertas abertos na conclusão desta auditoria.

## Testes executados

- 19 testes Python do sincronizador e adapters: aprovados.
- 17 contratos estáticos de UI/segurança: aprovados.
- 15 testes visuais responsivos CRM/B2B: aprovados.
- 4 testes reais no Chrome (CSP/SRI e importação Excel): aprovados.
- Teste transacional de isolamento B2B: acesso direto a produtos, perfis,
  clientes, código interno, helper fiscal e pedido de outro cliente bloqueado.
- Teste transacional do CRM ADMIN: catálogo, filtros e dashboard preservados.
- Testes HTTP controlados:
  - origem proibida: `403`;
  - senha B2B sem sessão: `401`;
  - tabela operacional como anônimo: `401`;
  - RPC interna como anônimo: `401`;
  - identidade pública autorizada: `200`.

## Proteção e recuperação

- Código-fonte, migrations e todas as Edge Functions estão no Git.
- A branch principal deve permanecer com force-push e exclusão desabilitados.
- CodeQL, Dependabot e secret scanning devem permanecer habilitados.
- Dados do banco não devem ser copiados para o repositório. Backup/PITR deve
  ser conferido no plano do Supabase antes da produção e testado com uma
  restauração controlada.

## Riscos residuais e ações operacionais

1. O repositório é público porque hospeda o GitHub Pages. Portanto o código do
   frontend é visível; isso é aceitável apenas porque não contém secrets.
2. GitHub Pages não permite configurar todos os headers de resposta, em
   especial `frame-ancestors`. Para proteção máxima contra framing, migrar o
   frontend para uma hospedagem com headers customizados antes da produção.
3. Confirmar no Supabase Auth: proteção contra senhas vazadas, limite de login,
   duração de sessão e MFA obrigatório para ADMIN.
4. Confirmar no GitHub que os proprietários usam 2FA e que não existem
   colaboradores desnecessários.
5. Ativar e testar backup/PITR conforme o plano contratado do Supabase.
6. Rotacionar periodicamente senha SMTP, segredo do sincronizador, refresh
   token Microsoft Graph e credenciais administrativas.

## Arquivos principais

- `supabase/migrations/081_security_hardening.sql`
- `supabase/functions/b2b-change-password/index.ts`
- `supabase/functions/cadastro-cliente/index.ts`
- `supabase/functions/consulta-cnpj/index.ts`
- `.github/workflows/security.yml`
- `.github/dependabot.yml`
- `supabase/tests/081_security_b2b_isolation_regression.sql`
- `supabase/tests/081_security_crm_regression.sql`
