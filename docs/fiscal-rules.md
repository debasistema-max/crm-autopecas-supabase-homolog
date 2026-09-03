# Governança das regras fiscais

## Ciclo de vida

| Status | Significado | Entra no cálculo? |
|---|---|---|
| `DRAFT` | Rascunho editável | Não |
| `VALIDATED` | Conferida, aguardando ativação | Não |
| `ACTIVE` | Validada e vigente | Sim |
| `REVIEW_REQUIRED` | Regra legada/importada que exige validação | Sim, com alerta |
| `EXPIRED` | Substituída ou vencida | Somente para sua vigência histórica |
| `DISABLED` | Desativada deliberadamente | Não |

As regras existentes foram classificadas como `REVIEW_REQUIRED` para preservar
a continuidade operacional sem declarar validação fiscal inexistente.

## Fluxo administrativo

```text
Nova regra -> DRAFT -> VALIDATED -> ACTIVE
Regra ativa -> nova versão DRAFT -> VALIDATED -> ACTIVE
                                      |
                                      +-> encerra a versão anterior
ACTIVE -> REVIEW_REQUIRED
qualquer estado -> DISABLED
```

Validação exige motivo, responsável, timestamp e fundamento/referência. O CRM
não verifica se o texto informado constitui fundamento legal suficiente; essa
decisão pertence ao responsável fiscal.

## Versionamento

Uma regra em uso não é editada. `create_fiscal_tax_rule_version` cria outro ID,
liga-o por `supersedes_rule_id` e mantém a versão anterior intacta. Cada
persistência incrementa `rule_version` e grava um snapshot imutável.

Na ativação de uma sucessora, a função encerra a versão anterior no dia anterior
ao início da nova. Todo o processo é transacional e passa pela mesma proteção de
períodos sobrepostos.

## Importações

Regra recebida do SAP é classificada `REVIEW_REQUIRED`; importação não equivale
a validação legal. Se uma nova lista tentar alterar uma regra ativa existente, o
commit é bloqueado como `REGRA_FISCAL_ATIVA_IMUTAVEL`. A próxima evolução deve
levar esse diagnóstico para o preview do lote antes da aprovação.

## Proibições

- não marcar regra como validada sem referência externa;
- não editar diretamente regra em uso;
- não apagar histórico;
- não usar zero para representar informação desconhecida;
- não reabrir período encerrado sem uma nova ação auditada.
