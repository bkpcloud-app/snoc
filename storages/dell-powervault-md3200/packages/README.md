# Pacote MD3200

O pacote contém template, coletores, instaladores, scripts de validação, unidades systemd e documentação completa para implantação do zero.

Como arquivos binários não são enviados diretamente pela integração, o ZIP está versionado em partes Base64.

```bash
chmod +x build-package.sh
./build-package.sh
unzip -l md3200-monitoring-v1.1.1.zip
```

A ISO proprietária do Dell MDSM não está incluída. O pacote contém o script de download oficial e a validação SHA-256.
