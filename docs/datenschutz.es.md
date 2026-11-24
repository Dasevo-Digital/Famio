# Información sobre privacidad de Famio

Versión: 24 de noviembre de 2026 · [Deutsch](datenschutz.md) · [English](datenschutz.en.md)

Esta es una traducción de la versión alemana. Si ambas difieren, prevalece
la versión alemana.

## Responsabilidad

Famio es software autoalojado. No existe un servicio central de Famio ni una
cuenta de usuario gestionada por el proyecto. La responsabilidad del
funcionamiento concreto, de las cuentas creadas y de los datos guardados en
ellas recae en la persona u organización que gestiona el servidor de Famio
correspondiente. Debe facilitar a los miembros un contacto accesible y, en la
medida necesaria, la demás información legalmente obligatoria.

## Datos tratados

Según el uso, Famio guarda en particular cuentas y sesiones, relaciones
familiares, calendarios, tareas, listas, mensajes, documentos, fotos,
existencias de la despensa, datos financieros, datos de los niños y de salud,
así como historiales de ubicación precisos. El servidor guarda además un
registro de auditoría de las operaciones de administración relevantes para la
seguridad. Qué categorías se tratan realmente lo decide la familia o el
responsable del servidor.

La base de datos y los archivos del servidor están cifrados, al igual que sus
copias de seguridad nocturnas. El servidor escribe el registro de auditoría en
el registro del sistema (por ejemplo, el journal), donde rige su conservación.
Los dispositivos guardan una base de datos local, también cifrada, y una caché
de archivos para el uso sin conexión. Su clave permanece en el llavero del
dispositivo; en iPhone y iPad ambas quedan excluidas de la copia de seguridad
del dispositivo. En Linux sin llavero, la clave se guarda en los ajustes de la
app tras el consentimiento.

Sin cifrar en el dispositivo quedan:

- la copia de un documento que alguien abre en otra app; se elimina en la
  siguiente limpieza, como muy tarde al cabo de una hora;
- las fotos y los archivos que la cámara, el selector de archivos y el
  escáner dejan para Famio, hasta que el sistema operativo vacía la caché de
  la app;
- los mosaicos de mapa en caché y, en el iPhone, los lugares de la familia
  para los avisos de lugares y las coordenadas del lugar del tiempo;
- los textos de los avisos mostrados, si «Mostrar contenido» está activado;
  en los recordatorios de medicamentos y de niños incluyen nombres;
- en iPhone y iPad, lo que llega a Famio desde otra app mediante «Compartir»,
  hasta que Famio lo recoge, como máximo un día.

Los datos de salud (medicamentos, datos de los niños con datos de emergencia
y registro, embarazos y documentos de la categoría Salud) solo los reciben los
adultos y las personas seleccionadas expresamente. Las fotos de las entradas
del registro de un niño, por ejemplo de una erupción, siguen las mismas
reglas. Las cuentas de servicio, por ejemplo para Home Assistant o una
pantalla de pared, nunca los reciben; las cuentas de niños, solo si están
seleccionadas. Los invitados y las cuentas de niños solo ven los eventos
privados si participan en ellos; las cuentas de servicio solo saben que el
tiempo está ocupado. Los avisos los mencionan sin título. Las cuentas de niños
solo reciben entradas de la bandeja familiar (a menudo cartas escaneadas) si
al archivarlas se marcó «También lo ven los niños», y siempre lo que ellas
mismas archivaron; los invitados y las cuentas de servicio nunca reciben la
bandeja. Los administradores pueden gestionar cuentas y contraseñas y, por
tanto, obtener técnicamente acceso a los datos de la familia; esas
operaciones aparecen en el registro de auditoría. Además, pueden consultar el
historial de ubicación de cualquier miembro y exportar los datos de toda la
familia (véase más abajo). Quien abre Famio por primera vez desde la barra
lateral de Home Assistant es invitado hasta que un administrador fija su rol.

## Conservación y eliminación

- Las sesiones caducan tras 90 días sin uso y pueden revocarse por
  dispositivo.
- Si la sección Ubicación está oculta en la administración del servidor, el
  servidor no acepta posiciones y los teléfonos pausan el envío de la
  ubicación.
- El historial de ubicación puede ajustarse entre 1 y 365 días; el valor
  predeterminado es de siete días. La última posición notificada se guarda
  hasta que llega una nueva, se pausa el envío o se elimina la cuenta.
  También desaparece al cerrar la sesión de Famio en el teléfono, salvo que
  otro dispositivo del miembro comparta la ubicación; fuera de un horario de
  compartir no puede verse. El servidor conserva el nombre del dispositivo y
  la hora del último aviso de cada dispositivo que comparte durante el mismo
  tiempo que el historial de ubicación; si comparten varios dispositivos de un
  miembro, cuenta el último que se activó.
- El servidor hace cada noche una copia de seguridad cifrada de su base de
  datos y conserva siete copias diarias y cuatro semanales. Las entradas
  eliminadas y las posiciones antiguas siguen en ellas hasta unas cinco
  semanas.
- Las copias de conflicto, que surgen al editar la misma entrada a la vez en
  dos dispositivos, contienen la versión anterior completa, también de datos
  de salud. Solo las ven las dos personas implicadas y se eliminan al cabo de
  60 días. Las marcas de eliminación sin contenido para la sincronización de
  los dispositivos se conservan 180 días; los avisos entregados por la
  conexión push propia de Famio, tres días.
- Al cerrar la sesión se eliminan la base de datos local, la caché y los
  datos de acceso del dispositivo. Si todavía hay cambios que no han llegado
  al servidor, porque la última sincronización no funciona o el servidor los
  retiene, la app pregunta antes. Si la sesión termina de otra forma (una
  contraseña nueva en otro dispositivo, «Cerrar sesión en todas partes»)
  mientras todavía hay cambios pendientes, solo esos cambios se quedan
  cifrados en el dispositivo; la app elimina el resto de los datos de la
  familia. Si la misma cuenta vuelve a iniciar sesión en el mismo servidor, la
  app vuelve a cargarlo todo y los envía. Se eliminan si inicia sesión otra
  cuenta o se inicia sesión en otro servidor, si se descartan en la página de
  inicio de sesión o al cabo de 14 días. Si el servidor ha eliminado la
  cuenta, la app no conserva nada.
- Si la base de datos local no se puede abrir (por ejemplo, porque está
  dañada), la app la aparta cifrada y vuelve a cargarlo todo. La copia
  apartada se elimina al cerrar la sesión, cuando inicia sesión otra cuenta y
  al cabo de 30 días.
- Los administradores pueden eliminar los datos de la familia en el servidor.
  La eliminación llega a los dispositivos con la siguiente sincronización.
  Antes se desconectan las conexiones con apps de listas, Paperless-ngx y
  PhotoVault, para que sus entradas no vuelvan.
- Los adultos y los invitados pueden eliminar su cuenta ellos mismos en la
  app; las cuentas de niños las elimina un adulto en la administración del
  servidor.
- Cuando se elimina una cuenta, el servidor borra sus datos de emergencia y
  todas las entradas que solo esa persona podía ver, como notas privadas,
  documentos con sus archivos y datos de salud; también de la papelera. Los
  datos de los niños se conservan como datos de la familia. Lo que ningún
  adulto aparte de esa persona podía ver lo ven después los demás tutores del
  niño; si no los hay, todos los adultos y quien más estuviera seleccionado.
  Para que los demás dispositivos de la cuenta se enteren, el servidor guarda
  valores de comprobación de sus sesiones hasta 90 días. Las copias de
  seguridad existentes siguen conteniendo los datos eliminados hasta que
  caducan.
- Las tareas, los eventos, las notas y los documentos eliminados de forma
  individual se conservan con sus adjuntos hasta 30 días en la papelera del
  servidor. Los miembros solo ven los elementos eliminados que todavía pueden
  ver según sus derechos actuales; para restaurarlos se necesitan además
  derechos de escritura. Pasado ese plazo ya no pueden recuperarse y se
  eliminan en la limpieza periódica. Una eliminación administrativa completa
  de los datos de la familia vacía también la papelera. Las marcas de
  eliminación para la sincronización de los dispositivos, las copias de
  conflicto y las copias de seguridad son independientes de ella.
- Cuando se solicita expresamente confirmar una responsabilidad, se guardan
  la respuesta, la persona responsable y la referencia a la tarea o al
  trayecto concretos. Solo son visibles para quienes pueden ver la entrada
  correspondiente. Los recordatorios de compromisos pendientes son opcionales
  y siguen los ajustes de push y de horas de silencio existentes.
- Las copias de seguridad y las copias en servicios externos de calendario,
  nube o push deben eliminarse por separado con su respectivo proveedor.

## Conexiones de red y destinatarios

**Tu propio servidor de Famio.** La app y el navegador envían al servidor
elegido por el responsable los datos de la familia, de la cuenta y del
dispositivo necesarios para la sincronización. HTTPS es el estándar. Un proxy
inverso público o un proveedor de alojamiento puede tratar técnicamente datos
de conexión.

**OpenStreetMap o un servidor de mapas propio.** Al abrir el mapa se cargan
mosaicos de la zona que se mira. El proveedor del mapa recibe la dirección IP
y las coordenadas de los mosaicos; de ellas puede deducirse la zona vista.
Como el mapa de la familia sigue las posiciones de los miembros y el mapa de
una llamada de emergencia se acerca mucho, eso revela aproximadamente dónde
está alguien. La web app envía además la dirección del servidor de Famio (sin
ruta) como referer, porque OpenStreetMap rechaza las solicitudes del
navegador sin referer. Un servidor de mapas propio mantiene esta consulta
dentro del propio servicio.

**Fuentes de la web app.** La web app carga los emojis y los caracteres de
otros idiomas desde tu propio servidor de Famio, no desde Google. Para los
caracteres chinos, japoneses y coreanos, el servidor descarga una vez el
archivo de fuente adecuado de Google Fonts y después lo guarda él mismo;
Google solo ve la dirección del servidor, no la de la familia.

**Open-Meteo.** El tiempo se activa por dispositivo. Se envían las
coordenadas del lugar «Casa» (si no existe, las del primer lugar),
redondeadas a 0,01 grados, y la dirección IP técnicamente necesaria. El
proveedor puede registrar las solicitudes según sus propias normas.

**Reconocimiento de texto y códigos de barras (Android).** Los eventos a
partir de fotos y el escáner de códigos de barras analizan las imágenes en el
teléfono; para ello las imágenes no salen del teléfono. Una foto o un escaneo
de un evento solo llega como adjunto a tu propio servidor de Famio si al
recogerlo sigue activado «Guardar el original en los eventos». En el paquete
pequeño para teléfonos de 64 bits, los modelos de reconocimiento proceden de
los servicios de Google Play, que los descargan una vez en el primer uso;
Google ve la solicitud del teléfono como en cualquier otra descarga de Google
Play. En Ajustes → «Reconocimiento sin Google Play» hay un paquete con modelos
integrados. Sin embargo, según Google, ML Kit también envía datos de
diagnóstico y de uso a Google con los modelos integrados: dispositivo,
versión de la app, valores de rendimiento y un identificador de la
instalación, no las imágenes ni los textos reconocidos. El escáner de
documentos procede siempre de los servicios de Google Play. En iPhone y iPad,
Vision de Apple reconoce texto y códigos de barras en el dispositivo sin
enviar nada.

**SMS en una llamada de emergencia (Android).** Si «SMS sin internet» está
activado y el teléfono no tiene conexión, la llamada de emergencia se envía
como SMS con el nombre y la posición, a través del operador de telefonía
móvil, a los números elegidos.

**Open Food Facts.** Una búsqueda por código de barras en la despensa envía
el código escaneado, y la búsqueda de valores nutricionales (tras un único
consentimiento por dispositivo) los términos de búsqueda, en ambos casos con
la dirección IP técnicamente necesaria, a `world.openfoodfacts.org`.

**Importación de recetas.** Quien importa una receta de una página web abre
esa página: la app directamente, la web app a través del servidor de Famio.
Si la página rechaza la solicitud de la app o no entrega ninguna receta, la
app lo intenta otra vez y después pide al servidor de Famio que descargue la
página; tu propio servidor conoce así la dirección de la página. La foto de
la receta la descarga siempre el servidor y la guarda como una subida. El
proveedor de la página ve la dirección IP del dispositivo o del servidor, nada
más.

**ntfy.** Solo después de configurarlo. El servidor ntfy configurado recibe el
tema secreto, la dirección IP y al menos un aviso breve; en algunos avisos
este también nombra a alguien («SOS de …», «… llega»). Si «Detalles» está
activado, se envía el aviso propiamente dicho, por ejemplo llegadas a
lugares, destinos de trayectos con hora de llegada o textos del chat. Además
hay un enlace para tocar con un identificador aleatorio del aviso, también
sin «Detalles». Qué abre Famio con él (por ejemplo, una tarea o un chat) solo
lo sabe la app del destinatario a través de su servidor de Famio, mientras el
aviso esté guardado allí; el identificador no revela ni la entrada ni quién
escribe a quién. Según su propia política de privacidad, el servicio público
ntfy.sh conserva los mensajes hasta doce horas y los entrega a los teléfonos a
través de Google (FCM) o de Apple. En el iPhone, sin Apple Push, ntfy es la
única vía para los avisos en segundo plano, también para las llamadas de
emergencia. Un servidor ntfy propio mantiene esto dentro del propio servicio.

**Web Push.** En el navegador, el servicio push del navegador (Google,
Mozilla, Apple o Microsoft) recibe el aviso cifrado, su urgencia y la
dirección pública del servidor de Famio; no puede leer el contenido.

**Servicios de calendario.** Las suscripciones ICS, CalDAV y Google Calendar
solo se usan después de configurarlos. En ese caso, los eventos o los datos
de acceso salen del servidor de Famio en la medida necesaria para la función.
Los eventos de Famio marcados como privados no se publican en las
suscripciones de calendario.

**Comprobación de versión.** Solo cuando un administrador toca «Buscar una
versión nueva» en la administración del servidor, su app consulta la lista
pública de versiones del proyecto en GitHub. No se envían datos de Famio;
GitHub ve la dirección IP del dispositivo. Si además se activa expresamente la
distribución de actualizaciones a través del servidor de Famio, el servidor
descarga de GitHub la lista de versiones y los archivos de instalación
correspondientes. Las descargas incompletas se reintentan en segundo plano.
GitHub y sus servidores de descarga ven la dirección IP del servidor de Famio;
no se envían contenidos de Famio. Sin esta activación, el servidor no hace
estas consultas.

**Bring! y Microsoft To Do.** Solo si un miembro conecta su cuenta y asigna
listas. El servidor de Famio envía entonces las entradas de las listas
asignadas (en las tareas, título, nota, vencimiento y estado de hecho; en las
listas de la compra, artículo, cantidad y estado de marcado) a Bring! (Bring!
Labs AG, Suiza) o a Microsoft (Microsoft Graph) y recoge de allí los cambios.
Solo se guardan los tokens de acceso, no la contraseña. La conexión con
Bring! usa una interfaz no documentada oficialmente. Una familia puede
desactivar la función por completo en la administración del servidor; al
desconectar una cuenta se eliminan los tokens y las asignaciones en el
servidor de Famio.

**Paperless-ngx y PhotoVault.** Solo si un administrador los conecta. El
servidor de Famio descarga entonces, con el acceso guardado, documentos con
sus archivos de Paperless-ngx (también los de la categoría Salud) o fotos y
cumpleaños de PhotoVault, y los muestra a los miembros elegidos. Además, Famio
pasa a PhotoVault las fotos del chat familiar con el nombre del remitente y la
hora, si así está configurado.

**Home Assistant.** Una cuenta de servicio para Home Assistant recibe
posiciones, eventos (los privados solo como tiempo ocupado), tareas, listas,
finanzas y el chat familiar, pero no datos de salud, documentos ni la bandeja.
Home Assistant guarda estos valores en su propio historial (recorder) según
sus ajustes; Famio no puede eliminarlos allí. En el modo «client», el
complemento guarda las sesiones de la barra lateral sin cifrar en su carpeta
de datos, que forma parte de las copias de seguridad de Home Assistant.

**OpenID Connect.** Si está activado el inicio de sesión mediante un
proveedor de identidad, el navegador, el servidor de Famio y el proveedor
configurado se conectan entre sí. El proveedor trata los datos de cuenta y de
conexión necesarios para iniciar sesión.

**Conexión push propia.** La variante push directa de Famio mantiene una
conexión entre el dispositivo y tu propio servidor de Famio y no usa ningún
proveedor push ajeno. En iOS, la entrega en segundo plano sin Apple Push está
limitada.

## Sin telemetría del proyecto

Famio no contiene análisis de uso, publicidad ni envío automático de informes
de fallos por parte del proyecto. Los proxies inversos y los servicios de
calendario, mapas, push o identidad añadidos por el responsable pueden llevar
sus propios registros.

## Exportación, información y rectificación

Cada miembro puede crear él mismo, en Ajustes → «Exportar mis datos», un
archivo ZIP con todos los datos que puede ver en Famio, incluidos sus archivos
y su historial de ubicación (con confirmación de la contraseña). Un
administrador adulto puede exportar los datos de toda la familia en la
administración del servidor, por ejemplo para trasladarse a otro servidor.
Esta exportación es una copia de seguridad completa: contiene también
entradas privadas, mensajes directos y datos de salud de otros miembros, así
como las últimas posiciones y las llamadas de emergencia, pero no los
historiales de ubicación. Aparece en el registro de auditoría, y los demás
adultos reciben un aviso. Ninguna de las dos exportaciones está cifrada. El
archivo solo se crea en el servidor por poco tiempo para la descarga y
después se elimina. Para la rectificación y la eliminación, así como para
más información, los miembros se dirigen al responsable de su servidor de
Famio. El proyecto Famio no tiene acceso a una instalación autoalojada y no
puede leer ni eliminar su contenido.
