#!/usr/bin/env python3
"""Seleciona um certificado RSA de assinatura do metadata SAML, sem rede."""
import argparse
import base64
import hashlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET


def extract(data, entity, fingerprint=''):
    if len(data) > 1024 * 1024 or b'<!DOCTYPE' in data.upper() or b'<!ENTITY' in data.upper():
        raise ValueError('Metadata excede o limite ou contém declaração XML não permitida')
    root = ET.fromstring(data)
    ns = {'m': 'urn:oasis:names:tc:SAML:2.0:metadata', 'd': 'http://www.w3.org/2000/09/xmldsig#'}
    if root.tag != '{'+ns['m']+'}EntityDescriptor' or root.get('entityID') != entity:
        raise ValueError('EntityID do metadata não corresponde ao realm esperado')
    certs = {}
    for node in root.findall('./m:IDPSSODescriptor/m:KeyDescriptor[@use="signing"]//d:X509Certificate', ns):
        text = re.sub(r'\s+', '', node.text or '')
        der = base64.b64decode(text, validate=True)
        certs[hashlib.sha256(der).hexdigest()] = der
    if fingerprint:
        selected = fingerprint.replace(':', '').lower()
        if not re.fullmatch('[0-9a-f]{64}', selected) or selected not in certs:
            raise ValueError('Fingerprint não corresponde a certificado de assinatura publicado')
        certs = {selected: certs[selected]}
    if len(certs) != 1:
        raise ValueError('Esperado um certificado de assinatura único; em rotação informe KEYCLOAK_SAML_CERT_SHA256')
    der = next(iter(certs.values()))
    pem = subprocess.check_output(['openssl', 'x509', '-inform', 'DER', '-outform', 'PEM'], input=der, stderr=subprocess.PIPE)
    subprocess.run(['openssl', 'x509', '-checkend', '0', '-noout'], input=pem, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    key = subprocess.check_output(['openssl', 'x509', '-pubkey', '-noout'], input=pem, stderr=subprocess.PIPE)
    subprocess.run(['openssl', 'rsa', '-pubin', '-noout'], input=key, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    return pem


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--entity', required=True)
    parser.add_argument('--fingerprint', default='')
    args = parser.parse_args()
    try:
        pem = extract(sys.stdin.buffer.read(1024 * 1024 + 1), args.entity, args.fingerprint)
    except (ValueError, ET.ParseError, subprocess.CalledProcessError) as exc:
        print('[ERROR] Certificado SAML inválido ou ambíguo: '+str(exc), file=sys.stderr)
        sys.exit(1)
    sys.stdout.buffer.write(pem)
