# Changelog técnico

## 2026-08-26 — Fase 2, entrega 1: módulos operacionais

- Dashboard, Parceiros e Produtos passaram a usar cabeçalhos e estados do
  design system compartilhado;
- filtros do dashboard foram separados da apresentação dos indicadores;
- cadastros de clientes e transportadoras receberam abas semânticas, hierarquia
  de formulário e barra de pesquisa responsiva;
- consulta gratuita de CNPJ foi preservada e revalidada nos dois cadastros;
- catálogo de produtos recebeu hierarquia consistente para pesquisa, filtros,
  resultados e detalhe;
- corrigidos alvos de toque dos períodos do dashboard e favoritos de produtos;
- criado smoke operacional isolado com dados simulados para os três módulos;
- nenhuma consulta, permissão, regra comercial, migration ou fórmula fiscal foi
  alterada.

Risco remanescente: as telas SAP de cotação e pedido possuem layout e regras
próprias. Serão migradas separadamente, com regressões fiscais antes de qualquer
mudança de comportamento.

## 2026-08-26 — Fase 1: fundação visual

- ampliados os tokens de design e estados semânticos;
- sidebar reorganizada por contexto e recolhível no desktop;
- topbar compactada com módulo, usuário e perfil;
- criado namespace `CrmUi` para componentes compartilhados;
- tabelas genéricas passaram a receber rótulos no mobile;
- adicionadas diretrizes de arquitetura, design, mobile e testes;
- nenhuma alteração de banco, migration ou fórmula fiscal.

Risco principal: módulos legados ainda possuem HTML próprio e serão migrados
progressivamente. A camada compartilhada foi adicionada sem remover contratos
anteriores.
