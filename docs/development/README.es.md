# Guía de desarrollo de GmailPing

[English](README.md) · [简体中文](README.zh-CN.md) · [日本語](README.ja.md) · **Español**

## Compilar y ejecutar las pruebas

En un Mac con macOS 13 o posterior, usa Xcode con Swift 5.9 o posterior. Ejecuta estos comandos desde la raíz del repositorio. Las pruebas simulan los clientes de Gmail y OAuth y se pueden ejecutar sin una cuenta de Google.

```sh
swift build
swift test
```

[GmailPingApp](../../Sources/GmailPingApp) contiene el menú de AppKit y las preferencias en SwiftUI. [GmailPingCore](../../Sources/GmailPingCore) gestiona OAuth, el llavero, la sincronización por cuenta y las notificaciones. Consulta las [pruebas de aceptación](../../Tests/GmailPingTests) si vas a cambiar el contador, las alertas o la selección de la bandeja de entrada.

## Conectar una cuenta de prueba

1. Habilita la [API de Gmail](https://console.cloud.google.com/apis/library/gmail.googleapis.com) en tu proyecto de Google Cloud. Configura la pantalla de consentimiento de OAuth con `openid` y `https://www.googleapis.com/auth/gmail.metadata`. Si la aplicación es externa y está en fase de pruebas, añade la dirección que vas a usar a la lista de usuarios de prueba.
2. Crea un [cliente OAuth de tipo aplicación de escritorio](https://console.cloud.google.com/auth/clients) y descarga su archivo JSON fuera del repositorio. Sustituye la ruta del ejemplo por la del archivo. El comando de copia conserva la configuración local si ya existe.
3. Compila y abre la aplicación, y conecta una cuenta siguiendo la [guía de usuario](../../README.es.md).

```sh
mkdir -p ~/.gmailping
cp -n /absolute/path/to/desktop-client.json ~/.gmailping/config.json
./scripts/build_app.sh --development
open dist/GmailPing.app
```

Al iniciar, se da prioridad a `GMAILPING_CLIENT_ID` y al valor opcional de `GMAILPING_CLIENT_SECRET`. Después se consulta `~/.gmailping/config.json` y por último la configuración incluida en la app. El archivo local también admite el formato JSON plano de versiones anteriores. Para probar la selección de bandeja, envía correo a dos cuentas y comprueba qué bandeja se abre desde el icono del menú y desde cada notificación. Marca como no leído un mensaje antiguo y comprueba que solo cambia el contador.

## Preparar una versión

Usa el mismo cliente OAuth de distribución en las sucesivas versiones para que las cuentas existentes puedan renovar sus tokens. El script valida el JSON del cliente de escritorio con Python 3, lo incluye en la app y genera en `dist/` un DMG universal y un archivo `.dmg.zip` que conserva el icono de Finder.

```sh
GMAILPING_OAUTH_CLIENT_FILE="/absolute/path/to/desktop-client.json" ./scripts/package_dmg.sh
```

El script firma el índice y el DMG con la clave Ed25519 de Sparkle guardada en el llavero de la máquina de publicación bajo `com.gmailping.app`. Incrementa `CFBundleVersion` en cada actualización. Sube `dist/appcast.xml`, el DMG y su ZIP a la versión correspondiente en GitHub Releases y márcala como Latest.

El script usa una firma ad hoc por defecto. Para distribuir con Developer ID, asigna a `GMAILPING_SIGN_IDENTITY` una identidad Developer ID Application y completa la notarización de Apple por separado. La configuración del cliente incluida en la app es legible. La autorización usa PKCE y una redirección a la interfaz de bucle local. Los tokens se guardan en el llavero. La distribución pública con el permiso restringido de metadatos de Gmail requiere la verificación de Google que corresponda. [OAuth para aplicaciones de escritorio](https://developers.google.com/identity/protocols/oauth2/native-app) · [Permisos de Gmail](https://developers.google.com/workspace/gmail/api/auth/scopes)

Los documentos originales (en chino simplificado) recogen los [requisitos del producto](../产品需求.md), el [diseño técnico](../技术方案.md), los [escenarios de aceptación](../开发与验收.md) y el [proceso de revisión de OAuth](../OAuth公开发布.md).
