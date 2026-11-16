#!/usr/bin/env python3
"""Regenerate public, test-only TLS keys/certificates. Requires cryptography.
Never use these keys outside the loopback regression tests.
"""
import datetime as dt
from pathlib import Path
import ssl
import ipaddress
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa
from cryptography.x509.oid import NameOID, ExtendedKeyUsageOID, ObjectIdentifier
def cert(key, name, issuer_cert=None, issuer_key=None, ca=False, san=None, eku=None, expired=False, pathlen=None, extra=None):
    now = dt.datetime(2025, 1, 1, tzinfo=dt.timezone.utc)
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,name)])
    b = (x509.CertificateBuilder().subject_name(subject).issuer_name(issuer_cert.subject if issuer_cert else subject)
         .public_key(key.public_key()).serial_number(x509.random_serial_number())
         .not_valid_before(now-dt.timedelta(days=2)).not_valid_after(now+dt.timedelta(days=-1 if expired else 36500))
         .add_extension(x509.BasicConstraints(ca,pathlen),True)
         .add_extension(x509.KeyUsage(True,False,False,False,False,ca,ca,None,None),True))
    if san is not None: b=b.add_extension(x509.SubjectAlternativeName(san),False)
    if eku is not None: b=b.add_extension(x509.ExtendedKeyUsage(eku),False)
    if extra: b=b.add_extension(*extra)
    return b.sign(issuer_key or key,hashes.SHA256())

def context(directory, name, leaf, key, chain=()):
    pem = directory / (name+'.pem'); priv = directory / (name+'.key')
    pem.write_bytes(b''.join(c.public_bytes(serialization.Encoding.PEM) for c in (leaf,*chain)))
    priv.write_bytes(key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()))
    ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(pem,priv)
    return ctx


directory=Path(__file__).resolve().parent/'tls'
directory.mkdir(exist_ok=True)
rootkey=ec.generate_private_key(ec.SECP256R1()); root=cert(rootkey,'Test root',ca=True,pathlen=1)
(directory/'ca.pem').write_bytes(root.public_bytes(serialization.Encoding.PEM))
key=ec.generate_private_key(ec.SECP256R1())
names=[x509.DNSName('localhost'),x509.IPAddress(ipaddress.ip_address('127.0.0.1'))]
leaf=cert(key,'localhost',root,rootkey,san=names,eku=[ExtendedKeyUsageOID.SERVER_AUTH])
context(directory,'good',leaf,key)
bad_cases={
    'hostname': dict(san=[x509.DNSName('wrong.invalid')]),
    'expired': dict(san=names,expired=True),
    'client-only': dict(san=names,eku=[ExtendedKeyUsageOID.CLIENT_AUTH]),
    'critical': dict(san=names,extra=(x509.UnrecognizedExtension(ObjectIdentifier('1.2.3.4.5'),b'\x05\x00'),True)),
    'constraints': dict(san=names,extra=(x509.NameConstraints([x509.DNSName('other.invalid')],None),True)),
    'dns-ip': dict(san=[x509.DNSName('127.0.0.1')]),
}
for name, kwargs in bad_cases.items(): context(directory,name,cert(key,'localhost',root,rootkey,**kwargs),key)
middlekey=ec.generate_private_key(ec.SECP256R1())
for is_ca in (False,True):
    middle=cert(middlekey,'Intermediate',root,rootkey,ca=is_ca)
    child=cert(key,'localhost',middle,middlekey,san=names)
    context(directory,'middle'+str(is_ca),child,key,(middle,))
limited=cert(rootkey,'Limited root',ca=True,pathlen=0)
(directory/'limited-ca.pem').write_bytes(limited.public_bytes(serialization.Encoding.PEM))
middle=cert(middlekey,'Intermediate',limited,rootkey,ca=True)
child=cert(key,'localhost',middle,middlekey,san=names)
context(directory,'pathlen',child,key,(middle,))
rsa_key=rsa.generate_private_key(public_exponent=65537,key_size=2048)
context(directory,'rsa',cert(rsa_key,'localhost',root,rootkey,san=names),rsa_key)
