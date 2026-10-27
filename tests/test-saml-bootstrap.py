"""Testa certificados e bootstrap com APIs sintéticas, sem kubeconfig ou rede."""
from pathlib import Path
import base64
import copy
import hashlib
import importlib.util
import json
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('cert', ROOT/'scripts/extract-saml-signing-cert.py')
cert = importlib.util.module_from_spec(spec); spec.loader.exec_module(cert)
ENTITY = 'https://keycloak.example/realms/observability'
MOCK = r'''#!/usr/bin/env python3
import sys,os,json,pathlib
args=sys.argv[1:];p=pathlib.Path(os.environ['STATE']);s=json.loads(p.read_text())
assert os.environ['ZABBIX_ADMIN_PASSWORD'] not in ' '.join(args), 'Senha em argv'
assert 'a'*32 not in ' '.join(args), 'Token em argv'
def end(value='',code=0):
 p.write_text(json.dumps(s));print(value,end='');sys.exit(code)
if pathlib.Path(sys.argv[0]).name=='curl':
 assert '-k' not in args and '--insecure' not in args
 assert '--cacert' in args
 if s.get('tls_failure'):end('TLS inválido',60)
 if args[-1].endswith('/descriptor'):end(pathlib.Path(os.environ['METADATA']).read_text())
 data=args[args.index('--data-binary')+1];assert data.startswith('@')
 req=json.loads(pathlib.Path(data[1:]).read_text());m=req['method'];q=req['params'];s['methods'].append(m)
 if m=='user.login':
  assert q['password']==os.environ['ZABBIX_ADMIN_PASSWORD']
  if s.get('login_failure'):end(json.dumps({'error':{'message':'negado'}}))
  end(json.dumps({'result':'a'*32}))
 if m=='user.logout':end(json.dumps({'result':True}))
 header=args[args.index('--header')+1];assert pathlib.Path(header[1:]).read_text().strip()=='Authorization: Bearer '+'a'*32
 if m=='userdirectory.get':end(json.dumps({'result':s['directories']}))
 if s.get('api_failure') and m=='role.get':end(json.dumps({'error':{'message':'negado'}}))
 if m=='usergroup.get':
  name=q['filter']['name'];id=s['groups'].get(name);end(json.dumps({'result':[{'usrgrpid':id}] if id else []}))
 if m=='usergroup.create':s['groups'][q['name']]=str(len(s['groups'])+1);end(json.dumps({'result':{'usrgrpids':['2']}}))
 if m=='usergroup.update':end(json.dumps({'result':{'usrgrpids':[q['usrgrpid']]}}))
 if m=='role.get':end(json.dumps({'result':[{'roleid':'3' if q['filter']['name']=='Super admin role' else '1'}]}))
 if m in ['userdirectory.create','userdirectory.update']:
  assert q['scim_status']=='0' and q['sign_assertions']=='1' and q['provision_status']=='1'
  s['directories']=[{**q,'userdirectoryid':'7'}];end(json.dumps({'result':{'userdirectoryids':['7']}}))
 if m=='authentication.update':
  assert q['saml_auth_enabled']=='1';s['auth']=q;end(json.dumps({'result':{'authenticationid':'1'}}))
 raise AssertionError(m)
else:
 if args[:2]==['-n','zabbix']:args=args[2:]
 if args[:3]==['get','configmap','zabbix-saml-idp']:
  if s.get('cm_denied'):end('Forbidden',1)
  end(json.dumps({'data':{'idp.crt':s['certificate']}}) if s['certificate'] else '')
 if args[:3]==['create','configmap','zabbix-saml-idp']:
  file=next(a.split('=',2)[2] for a in args if a.startswith('--from-file='));end(json.dumps({'data':{'idp.crt':pathlib.Path(file).read_text()}}))
 if args[:2]==['apply','--server-side']:
  s['certificate']=json.load(sys.stdin)['data']['idp.crt'];s['cm_writes']+=1;end()
 if args[:3]==['rollout','restart','deployment/zabbix-web']:s['restarts']+=1;end()
 if args[:3]==['rollout','status','deployment/zabbix-web']:end()
 raise AssertionError(args)
'''

def metadata(keys, entity=ENTITY, prefix='ds'):
    body=''.join(f'<m:KeyDescriptor use="{use}"><{prefix}:KeyInfo><{prefix}:X509Data><{prefix}:X509Certificate>{value}</{prefix}:X509Certificate></{prefix}:X509Data></{prefix}:KeyInfo></m:KeyDescriptor>' for use,value in keys)
    return f'<m:EntityDescriptor xmlns:m="urn:oasis:names:tc:SAML:2.0:metadata" xmlns:{prefix}="http://www.w3.org/2000/09/xmldsig#" entityID="{entity}"><m:IDPSSODescriptor>{body}</m:IDPSSODescriptor></m:EntityDescriptor>'.encode()

with tempfile.TemporaryDirectory() as tmp:
    p=Path(tmp)
    values=[]
    for i in range(2):
        subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-subj',f'/CN=synthetic-{i}','-days','1','-keyout',str(p/f'key{i}'),'-out',str(p/f'cert{i}')],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        der=subprocess.check_output(['openssl','x509','-in',str(p/f'cert{i}'),'-outform','DER'])
        values.append(base64.b64encode(der).decode())
    good=metadata([('encryption',values[1]),('signing',values[0])],prefix='public')
    pem=cert.extract(good,ENTITY)
    assert b'BEGIN CERTIFICATE' in pem
    print('PASS: seleção por namespace e uso signing, ignorando encryption')
    assert cert.extract(metadata([('signing',values[0]),('signing',values[0])]),ENTITY)==pem
    print('PASS: certificado repetido é deduplicado')
    ambiguous=metadata([('signing',v) for v in values])
    fingerprint=hashlib.sha256(base64.b64decode(values[0])).hexdigest()
    assert cert.extract(ambiguous,ENTITY,fingerprint)==pem
    print('PASS: seleção explícita em rotação')
    for name,xml,fp in [('sem assinatura',metadata([('encryption',values[0])]),''),('ambíguo',ambiguous,''),('entity incorreto',metadata([('signing',values[0])],entity='https://evil.example'),''),('DTD',b'<!DOCTYPE test>'+good,''),('XML inválido',b'<bad',''),('base64 inválido',metadata([('signing','!!!')]),''),('certificado inválido',metadata([('signing',base64.b64encode(b'invalido').decode())]),''),('fingerprint ausente',good,'0'*64)]:
        try:cert.extract(xml,ENTITY,fp)
        except (ValueError, cert.ET.ParseError, subprocess.CalledProcessError):print('PASS: rejeitado',name)
        else:raise AssertionError(name)
    (p/'curl').write_text(MOCK);(p/'curl').chmod(0o755)
    (p/'oc').write_text(MOCK);(p/'oc').chmod(0o755)
    meta=p/'metadata.xml';meta.write_bytes(good)
    state=p/'state.json'
    base={'directories':[],'groups':{'Zabbix administrators':'1'},'methods':[],'certificate':'','cm_writes':0,'restarts':0}
    env={**os.environ,'PATH':tmp+':'+os.environ['PATH'],'STATE':str(state),'METADATA':str(meta),'ZABBIX_ADMIN_PASSWORD':'synthetic-password-123','ZABBIX_MANAGE_GRAFANA_DATASOURCE':'false','BOOTSTRAP_CA_FILE':str(p/'cert0'),'KEYCLOAK_BASE_URL':'https://keycloak.example','KEYCLOAK_REALM':'observability','ZABBIX_API_URL':'https://zabbix.example/api_jsonrpc.php','ZABBIX_BASE_URL':'https://zabbix.example','ZABBIX_ENABLE_SAML_SCIM':'false'}
    def run(s):
        state.write_text(json.dumps(s));r=subprocess.run(['bash',str(ROOT/'scripts/bootstrap-zabbix.sh')],env=env,text=True,capture_output=True,timeout=20)
        assert env['ZABBIX_ADMIN_PASSWORD'] not in r.stdout+r.stderr
        return r,json.loads(state.read_text())
    r,s=run(copy.deepcopy(base));assert r.returncode==0,(r.stdout,r.stderr)
    assert s['cm_writes']==s['restarts']==1 and s['auth']['saml_jit_status']=='1'
    assert 'userdirectory.create' in s['methods']
    print('PASS: bootstrap completo SAML/JIT sem criar usuário técnico')
    s['methods']=[];r,s2=run(s);assert r.returncode==0,(r.stdout,r.stderr)
    assert s2['cm_writes']==s2['restarts']==1 and 'userdirectory.update' in s2['methods'] and 'userdirectory.create' not in s2['methods']
    print('PASS: reexecução sem duplicar diretório nem reiniciar certificado igual')
    for name,change in [('TLS inválido',{'tls_failure':True}),('login negado',{'login_failure':True}),('outro IdP',{'directories':[{'userdirectoryid':'8','idp_entityid':'https://outro.example'}]}),('múltiplos diretórios',{'directories':[{},{}]}),('ConfigMap negado',{'cm_denied':True}),('API negada',{'api_failure':True})]:
        s=copy.deepcopy(base);s.update(change);r,s=run(s);assert r.returncode!=0,name
        assert 'authentication.update' not in s['methods'] and 'userdirectory.create' not in s['methods']
        if name!='API negada':assert s['cm_writes']==0,name
        print('PASS: interrompido',name)
print('PASS: 19 cenários sintéticos; nenhuma chamada real de cluster/API')
