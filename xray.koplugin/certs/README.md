# Mozilla CA bundle fallback

`ca-bundle.crt` is the **unmodified** Mozilla public CA certificate store converted to PEM and published by the curl project. It supplies a plugin-local trust store when KOReader/device CA bundles are unavailable. It does not disable certificate-chain, validity, or hostname verification.

## Provenance

- Publisher and conversion documentation: <https://curl.se/docs/caextract.html>
- Pinned download: <https://curl.se/ca/cacert-2026-09-25.pem>
- Published checksum: <https://curl.se/ca/cacert-2026-09-25.pem.sha256>
- Mozilla source date: **2026-09-25 03:12:01 UTC**
- Retrieved: **2026-09-29 UTC**
- Certificates: **121**
- Size: **188900 bytes**
- File SHA-256: `a41b5d356aea97a529fe27e0f7316d2f9d946d75927476cf9cf1b90637d00505`
- Conversion tool recorded in PEM: `mk-ca-bundle.pl version 1.33`
- Mozilla source location recorded by publisher: <https://raw.githubusercontent.com/mozilla-firefox/firefox/refs/heads/release/security/nss/lib/ckfw/builtins/certdata.txt>

The file SHA-256 above is the digest of the complete downloaded PEM. The SHA256 comment inside the PEM is conversion/source metadata, not the file digest. The downloaded file matched curl's separately published SHA-256.

## License

The curl CA extraction documentation states that this converted Mozilla certificate store is licensed under **Mozilla Public License 2.0**, not curl's software license. The bundle remains under MPL-2.0 as a separate component. Preserve its existing comments and notices when redistributing it.

The complete license is included in [`LICENSE-MPL-2.0.txt`](LICENSE-MPL-2.0.txt), retrieved unchanged from <https://www.mozilla.org/media/MPL/2.0/index.txt>. The authoritative license is also available at <https://www.mozilla.org/en-US/MPL/2.0/>. Bundle/source provenance and update locations are listed above for recipients. Including this separate data file does not change the license of unrelated plugin files.

## Security and maintenance

- This is a maintained snapshot, not a permanently valid or automatically refreshed trust store. Review Mozilla/curl CA updates for every plugin release and promptly for trust-store security changes.
- Update by selecting a dated bundle on curl's extraction page, downloading it and its published checksum over verified HTTPS, and comparing the complete file SHA-256 before replacing this file. Keep the PEM unchanged and update this document's date, source URL, certificate count, size, and digest.
- Never fetch a replacement using disabled certificate verification. Prefer distributing reviewed updates in plugin releases rather than automatically downloading trust roots on the reader.
- Run the secure transport's real TLS checks using the new bundle explicitly, including rejection of untrusted chains and wrong SAN hostnames. Confirm the release artifact contains this directory and the module can locate it from KOReader's normal working directory. A relative module source path requires that working directory to remain stable.
- The curl publisher warns that **Mozilla/browser-specific trust constraints are not all preserved by PEM conversion**. This is the conventional OpenSSL CA-bundle model, not a claim of Firefox-equivalent trust policy. Keep the transport restricted to the intended official HTTPS hosts with independent SAN verification.
- An explicitly configured invalid CA file must fail closed. Do not silently replace it with this fallback or retry failed certificate validation with weaker settings.

From the repository root, verify the distributed file:

```sh
printf '%s\n' 'a41b5d356aea97a529fe27e0f7316d2f9d946d75927476cf9cf1b90637d00505  xray.koplugin/certs/ca-bundle.crt' | sha256sum --check
```
