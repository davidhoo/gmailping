# GmailPing

[English](README.md) · [简体中文](README.zh-CN.md) · [日本語](README.ja.md) · **Español**

Consulta en la barra de menús del Mac cuántos mensajes sin leer tienes entre todas tus bandejas de entrada de Gmail. Al hacer clic en una notificación, se abre en tu navegador predeterminado la bandeja que recibió el mensaje.

## Instalar y conectar Gmail

1. Descarga el archivo `.dmg` universal de la [página de versiones](https://github.com/davidhoo/gmailping/releases). Es compatible con los Mac con chip de Apple o procesador Intel que usen macOS 13 o posterior. Si eliges el archivo `.dmg.zip`, descomprímelo primero. La versión 1.1.0 lleva una firma ad hoc y carece de notarización de Apple.
2. Abre la imagen de disco, arrastra **GmailPing** a **Aplicaciones** e inicia la app desde allí. Verás un sobre en la barra de menús.
3. Haz clic en el sobre para abrir las preferencias. La interfaz está en chino simplificado. En **账号** (Cuentas), selecciona **添加 Google 账号...** (Añadir cuenta de Google). Elige tu cuenta de Gmail en el navegador y concede el acceso. Repite el proceso para cada cuenta que quieras consultar.
4. Para recibir avisos, permite las notificaciones cuando macOS te lo pregunte. Puedes ajustar el sonido y el intervalo entre comprobaciones en **偏好设置** (Preferencias).

Desde la versión 1.1.0, GmailPing busca actualizaciones a diario en GitHub Releases y ofrece instalarlas. Haz clic con el botón derecho en el sobre para buscar ahora (**检查应用更新…**) o desactivar las comprobaciones automáticas (**自动检查应用更新**). Para pasar de una versión anterior a la 1.1.0, instálala manualmente.

## Abrir la bandeja con correo sin leer

Haz clic en el sobre. Si solo una cuenta tiene mensajes sin leer, se abrirá directamente. Si hay varias, podrás elegir entre sus direcciones y ver cuántos mensajes quedan por leer en cada una. Si no se ha detectado correo sin leer, se abrirá la bandeja predeterminada. Haz clic con el botón derecho en el sobre para ver cuándo se comprobó cada cuenta, buscar correo en ese momento o cambiar la cuenta predeterminada.

Los mensajes nuevos detectados en la misma bandeja durante una comprobación se agrupan en una sola notificación. Marcar un mensaje antiguo como no leído actualiza el contador sin generar un aviso de correo nuevo.

Al abrir una bandeja, GmailPing consulta esa cuenta a los 5 segundos y después cada 10 segundos durante un minuto como máximo. Si el contador llega a cero, recupera el intervalo habitual. El modo manual omite estas consultas.

## Privacidad y ayuda

Tu Mac se conecta directamente a Google para consultar recuentos, identificadores de mensajes y etiquetas. El contenido y los archivos adjuntos permanecen en Gmail. Los tokens de cada cuenta se guardan en el llavero de macOS. Para desconectar una cuenta, elimínala en **账号**. También puedes revocar el acceso desde tu cuenta de Google. [Política de privacidad (en chino)](https://davidhoo.github.io/gmailping/privacy/) · [Conexiones de la cuenta de Google](https://myaccount.google.com/connections)

Si necesitas ayuda, indica las versiones de macOS y GmailPing en tu [correo al equipo de soporte](mailto:coolbor@gmail.com).

[Guía de desarrollo](docs/development/README.es.md) · [Licencia MIT](LICENSE)
