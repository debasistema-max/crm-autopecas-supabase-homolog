# Sincronismo independente do catalogo instalado

## Producao

Nesta branch o executor aceita exclusivamente o projeto de producao
`doenvnjzrecrtvwooaai`. Use a pasta privada
`IPSCRM\InstalledCatalogWorkerProduction` e a tarefa `IPS Catalogo Local Producao`.
O roteiro de homologacao abaixo e referencia historica; nao reutilize sua senha,
configuracao ou tarefa. Consulte `PRODUCTION_PROMOTION_20261022.md` para a
sequencia de promocao e os limites operacionais.

## Fluxo

Central de Dados > **Sincronizar Catalogo IPS** cria uma solicitacao ADMIN.
O executor Windows consulta a fila a cada dois minutos e le exclusivamente
`%LOCALAPPDATA%\catalogo_ips\_up_\data\catalog.db` e o `manifest.json` instalado.
Nao baixa outra base de catalogo da internet. Apenas verifica as URLs de fotos
autorizadas pelo manifesto. O aplicativo original nunca e executado ou alterado.

Windows precisa estar ligado, com internet e o usuario conectado. Nao ha listener
HTTP local, porta de entrada, Docker ou credencial privilegiada no navegador.
Celulares podem solicitar pelo CRM; a leitura sempre acontece neste computador.
Solicitacoes pendentes expiram apos 24h; execucoes expiram apos 30 minutos.

O Excel, seus botoes, seus lotes, agendamento e executor permanecem independentes.

## Garantias

- Somente ADMIN ativo e com sessao atual pode solicitar e consultar historico.
- Papel PostgreSQL exclusivo `ips_catalog_worker`, sem acesso direto a tabelas.
- Codigo exato, banco SQLite somente leitura e fotos limitadas ao manifesto.
- Somente oito campos tecnicos do importador existente; preenche vazios e
  substitui apenas o bloco de origem em detalhes. Notas manuais sao preservadas.
- Nao altera preco, estoque, descricao SAP, ano, ativo, fiscal, pedidos ou cotacoes.
- Snapshot local anterior a gravacao; auditoria antes/depois e log com solicitante.
- Finalizacao, auditoria e status em uma transacao PostgreSQL. Divergencia do
  snapshot bloqueia tudo. Reenvio da finalizacao do mesmo job nao duplica auditoria.
- TLS verifica certificado e hostname. Credencial de producao nunca e utilizada.
- Nao cria produtos novos. Itens sem correspondencia e fotos indisponiveis contam
  como ignorados/alertas. O executor nao reutiliza o sincronismo do Excel.

## Preparacao administrativa

1. Aplicar `108_installed_catalog_queue.sql` somente em homologacao, apos backup.
2. Provisionar LOGIN e senha aleatoria para `ips_catalog_worker` por uma conexao
   administrativa segura. Nao colocar senha em migration, argumento de processo,
   historico do shell, repositorio ou chat. Nao conceder roles adicionais.
3. Instalar as dependencias fixadas com `npm ci` no checkout do executor.
4. Criar a pasta privada `%LOCALAPPDATA%\IPSCRM\InstalledCatalogWorkerHomolog`.
   Guardar nela um JSON de configuracao com estas chaves:

```json
{
  "project": "mtwvxyvpnbgwgltelozw",
  "host": "POOLER_DA_HOMOLOGACAO.pooler.supabase.com",
  "port": 5432,
  "user": "ips_catalog_worker.mtwvxyvpnbgwgltelozw",
  "password": "SENHA_ALEATORIA_PRIVADA",
  "database": "CAMINHO_ABSOLUTO_catalog.db",
  "manifest": "CAMINHO_ABSOLUTO_manifest.json",
  "python": "CAMINHO_ABSOLUTO_python.exe",
  "ca": "CAMINHO_ABSOLUTO_supabase-prod-ca-2021.crt",
  "evidence": "PASTA_PRIVADA_ABSOLUTA_DE_EVIDENCIAS"
}
```

5. Usar o certificado CA oficial Supabase, sem desativar verificacao TLS.
6. Registrar a tarefa com PowerShell (nao requer elevar para administrador):

```powershell
.\scripts\register_installed_catalog_worker.ps1 `
  -ConfigPath "$env:LOCALAPPDATA\IPSCRM\InstalledCatalogWorkerHomolog\config.json" `
  -NodePath 'C:\Program Files\nodejs\node.exe'
```

O registro restringe a pasta privada ao usuario atual e SYSTEM, testa a conexao
sem consumir fila e so entao registra tarefa interativa, limitada, sem senha nos
argumentos, com instancias sobrepostas bloqueadas. Verificar ACL tambem em
arquivos existentes com permissoes explicitas; nao compartilhar esta pasta.
O wrapper usa RemoteSigned somente naquele processo, sem alterar a politica
global do Windows; nao utiliza ExecutionPolicy Bypass. A janela fica oculta.
O registro resolve os caminhos fisicos da configuracao, leitor, banco, manifesto
e certificado. Isso evita diferencas de visibilidade entre aplicativos Windows
empacotados e o Agendador. As evidencias ficam junto da configuracao fisica,
na mesma pasta privada; nenhuma credencial e impressa pelo preparador.

## Teste e operacao

1. ADMIN: solicitar no botao; outra solicitacao simultanea deve reutilizar a mesma.
2. Executor le catalogo e grava `before.json`, `plan.json` e `result.json` na pasta
   de evidencias, exclusiva por execucao. Nao publicar esses arquivos.
3. Historico proprio deve passar de aguardando computador a leitura e concluido.
4. Conferir quantidade alterada, sem alteracao e nao encontrada. Auditoria fica
   em `product_catalog_metadata_audit`, vinculada ao batch; log tem solicitante.
5. Usuario nao ADMIN e sessao substituida: RPCs devem bloquear.
6. Desligar computador: fica aguardando, nunca dispara Excel ou baixa outra base.
7. Falha na leitura ou concorrencia: lote falha sem alteracao parcial dos produtos.

O script retorna codigo 0 em ready/idle/completed e 1 em falha. Historico e log
no banco sao a referencia se houver perda da resposta apos commit. Falhas nao
eliminam evidencias anteriores. O cache de linhas/grupos tem TTL de dez minutos.

Para suspender: desabilitar a tarefa `IPS Catalogo Local Homolog`; revogar LOGIN
do papel se houver suspeita de vazamento. Nao apagar auditoria ou produtos.
Nao habilitar em producao sem revisao e autorizacao especifica.
# Catalogo instalado como pacote Windows

Quando o catalogo estiver instalado pela Microsoft Store, configure
`catalogPackageFamily` como
`BrunoRImbanoJunior.CatlogoYokomitsu_m47cmv7cfchvj`.
O executor consulta o registro Appx do usuario a cada execucao e resolve
`data/catalog.db` e `manifest.json` dentro do pacote instalado em WindowsApps.
Isso acompanha a troca de pasta em atualizacoes, sem alterar ACLs de WindowsApps,
usar copias temporarias ou buscar uma base online. Pacote, origem ou arquivos
divergentes bloqueiam a execucao. Configuracoes antigas sem essa propriedade
continuam aceitando os caminhos locais explicitos.

`--check` valida acesso aos arquivos e a conexao restrita, sem consumir a fila.
O modo normal so importa quando houver uma solicitacao ADMIN na fila. Mantenha
credenciais diferentes por ambiente, fora do Git, em pasta privada para usuario
e SYSTEM; nao conceda acesso direto a tabelas ao executor.

