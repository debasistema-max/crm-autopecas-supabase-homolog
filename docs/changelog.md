# Changelog técnico

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
