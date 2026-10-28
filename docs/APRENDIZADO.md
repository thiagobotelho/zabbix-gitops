# SAML, bootstrap e integrações


Keycloak autentica via SAML e o Zabbix associa atributos a usuários/grupos. Bootstrap via API deve localizar recursos existentes antes de criar e deve preservar senhas existentes sem reset implícito. Teste primeira execução e reexecução em ambiente descartável, inclusive grupo sem permissão. Grafana datasource tem credencial e papel próprios.


O caminho automatizado de certificado e IdP está em `scripts/bootstrap-zabbix.sh`.
O helper XML seleciona assinatura por namespace/uso e rejeita ambiguidade.
Leia o procedimento de execução somente SAML no README e identifique quais
recursos são alterados antes de executar. HTTPS e assinatura SAML usam
certificados com propósitos diferentes.

## Separar os cadastros

SAML/JIT associa identidade e grupos de acesso; hosts, templates e host groups de monitoramento são outra configuração. Use o bootstrap para o IdP e o procedimento de monitoramento para os ativos. Um login bem-sucedido não comprova ingestão de métricas nem permissão do datasource Grafana.
