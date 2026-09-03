# Validação fiscal

## O que os testes comprovam

Os testes automatizados comprovam integridade de software e preservação dos
resultados conhecidos. Eles não substituem validação tributária por profissional
habilitado nem transformam planilha/SAP em fonte legal.

Em 03/09/2026, 11 arquivos SQL passaram contra a homologação, todos terminando
com `ROLLBACK`:

- golden cases PR→PR, SP→SP e PR→SC;
- carga e reimportação dos tipos SAP;
- preservação de campo vazio e field mask;
- igualdade entre snapshot de cotação e pedido;
- bloqueio de documento fiscal inválido;
- UF, alíquotas e conflito de vigência;
- histórico imutável e incremento de versão;
- rascunho fora do cálculo;
- fundamento obrigatório para validação;
- substituição atômica e resolução por data;
- desativação sem exclusão;
- bloqueio para VENDEDOR e acesso anônimo.

## Golden cases preservados

| Rota | Base | Tributos | Final | Status |
|---|---:|---:|---:|---|
| PR→PR | 232,000000 | 115,854460 | 347,854460 | `OK` |
| SP→SP | 232,000000 | 114,791931 | 346,791931 | `OK` |
| PR→SC | 232,000000 | 31,900000 | 263,900000 | `OK_SEM_ST` |

## Estado fiscal não certificado

As 76 regras legadas estão `REVIEW_REQUIRED`. PIS, COFINS e FCP ausentes
continuam como `NULL`; o perfil `LEGACY_REVENDA` permanece compatível com o caso
observado, mas requer validação fiscal externa. Nenhum desses pontos deve ser
silenciosamente promovido a validado.

## Próximas validações

1. anexar fundamento oficial por regra/rota/NCM;
2. validar o perfil `LEGACY_REVENDA` e seu alcance;
3. definir aplicabilidade de PIS, COFINS e FCP por contexto operacional;
4. comparar política de arredondamento com documento fiscal/SAP;
5. executar golden cases aprovados pelo responsável fiscal antes de promover
   regras para `ACTIVE`.
