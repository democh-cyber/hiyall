package billing

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// googleKeyFile writes a service-account key file (a fresh RSA key) and returns its path and the account.
func googleKeyFile(t *testing.T, tokenURI string) (string, GoogleAccount) {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	der, _ := x509.MarshalPKCS8PrivateKey(key)
	acc := GoogleAccount{Type: "service_account", ClientEmail: "billing@example.iam.gserviceaccount.com", PrivateKeyID: "kid1",
		PrivateKey: string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})), TokenURI: tokenURI}
	raw, _ := json.Marshal(acc)
	path := filepath.Join(t.TempDir(), "sa.json")
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	return path, acc
}

// appleChain is a fake Apple PKI: a root, an intermediate and a leaf, with Apple's marker extensions.
type appleChain struct {
	root, inter, leaf *x509.Certificate
	leafKey           *ecdsa.PrivateKey
	rootPEM           []byte
}

func newAppleChain(t *testing.T, markers bool) *appleChain {
	t.Helper()
	gen := func() *ecdsa.PrivateKey {
		k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
		return k
	}
	serial := int64(1)
	make1 := func(subject string, isCA bool, key *ecdsa.PrivateKey, parent *x509.Certificate, parentKey *ecdsa.PrivateKey, ext ...pkix.Extension) *x509.Certificate {
		serial++
		tpl := &x509.Certificate{SerialNumber: big.NewInt(serial), Subject: pkix.Name{CommonName: subject}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(24 * time.Hour),
			IsCA: isCA, BasicConstraintsValid: true, ExtraExtensions: ext}
		if isCA {
			tpl.KeyUsage = x509.KeyUsageCertSign
		} else {
			tpl.KeyUsage = x509.KeyUsageDigitalSignature
		}
		signer, signerKey := tpl, key
		if parent != nil {
			signer, signerKey = parent, parentKey
		}
		der, err := x509.CreateCertificate(rand.Reader, tpl, signer, &key.PublicKey, signerKey)
		if err != nil {
			t.Fatal(err)
		}
		c, _ := x509.ParseCertificate(der)
		return c
	}
	rootKey, interKey, leafKey := gen(), gen(), gen()
	root := make1("Fake Apple Root", true, rootKey, nil, nil)
	var interExt, leafExt []pkix.Extension
	if markers {
		interExt = []pkix.Extension{{Id: oidAppleIntermediate, Value: []byte{5, 0}}}
		leafExt = []pkix.Extension{{Id: oidAppleLeaf, Value: []byte{5, 0}}}
	}
	inter := make1("Fake Apple WWDR", true, interKey, root, rootKey, interExt...)
	leaf := make1("Fake Apple Leaf", false, leafKey, inter, interKey, leafExt...)
	return &appleChain{root, inter, leaf, leafKey, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: root.Raw})}
}

// sign makes an Apple-style ES256 JWS over payload, with the chain in x5c.
func (c *appleChain) sign(t *testing.T, payload any) string {
	t.Helper()
	header, _ := json.Marshal(map[string]any{"alg": "ES256", "x5c": []string{base64.StdEncoding.EncodeToString(c.leaf.Raw), base64.StdEncoding.EncodeToString(c.inter.Raw), base64.StdEncoding.EncodeToString(c.root.Raw)}})
	body, _ := json.Marshal(payload)
	signing := b64(header) + "." + b64(body)
	sum := sha256.Sum256([]byte(signing))
	r, s, err := ecdsa.Sign(rand.Reader, c.leafKey, sum[:])
	if err != nil {
		t.Fatal(err)
	}
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	return signing + "." + b64(sig)
}

// appleClient is a client for the fake chain whose API is baseURL (both hosts).
func appleClient(t *testing.T, c *appleChain, prod, sandbox string, allowSandbox bool) *Apple {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, _ := x509.MarshalPKCS8PrivateKey(key)
	dir := t.TempDir()
	keyFile, rootFile := filepath.Join(dir, "k.p8"), filepath.Join(dir, "root.pem")
	_ = os.WriteFile(keyFile, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), 0o600)
	_ = os.WriteFile(rootFile, c.rootPEM, 0o600)
	a, err := NewApple("app.hiyall.test", "issuer-1", "KEY1", keyFile, rootFile, allowSandbox)
	if err != nil {
		t.Fatal(err)
	}
	a.ProductionURL, a.SandboxURL = prod, sandbox
	return a
}

var _ = asn1.ObjectIdentifier{}
