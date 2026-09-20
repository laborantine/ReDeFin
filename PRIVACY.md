# Confidentialité et données locales - ReDeFin

ReDeFin est un client Jellyfin pour Freebox Player. Cette note décrit les données
utilisées par l'application, leur stockage local et les règles appliquées au build
public / FreeStore.

L'objectif de ReDeFin est de conserver une expérience simple et fluide, notamment
en permettant à l'utilisateur de retrouver sa session Jellyfin après un
redémarrage de l'application, tout en limitant autant que possible l'exposition
des données sensibles.

## Données traitées

ReDeFin peut traiter, uniquement pour assurer son fonctionnement :

- l'URL du serveur Jellyfin configuré ;
- l'identifiant du profil Jellyfin (`userId`) ;
- le nom et l'image du profil ;
- un jeton d'accès Jellyfin (`accessToken`) ;
- des identifiants de médias, de bibliothèques et de sources nécessaires à la
  navigation et à la lecture ;
- des préférences locales d'interface et de lecture ;
- un identifiant technique aléatoire propre à l'installation ReDeFin (`DeviceId`),
  utilisé pour distinguer cette Freebox des autres clients auprès de Jellyfin ;
- des informations techniques liées à la lecture ;
- des erreurs réseau techniques.

ReDeFin n'utilise pas ces informations à des fins publicitaires et n'ajoute pas
de service d'analytics applicatif dans le build public.

## Session Jellyfin et jeton d'accès

Afin d'éviter de demander une nouvelle authentification à chaque démarrage,
ReDeFin peut conserver localement les informations nécessaires à la restauration
de la session Jellyfin.

Dans le build public / FreeStore :

- le jeton Jellyfin n'est pas enregistré en clair dans les structures de profil
  ou de préférences ;
- le jeton peut être conservé dans un stockage local de session dédié afin de
  permettre la reconnexion automatique ;
- la représentation persistée du jeton est obfusquée avant son enregistrement ;
- cette obfuscation a pour objectif d'éviter l'exposition accidentelle du jeton
  sous forme directement lisible, mais **elle ne constitue pas un chiffrement
  cryptographique fort ni un coffre matériel sécurisé** ;
- ReDeFin ne considère donc jamais `fbx.application.Settings` comme un stockage
  de secrets offrant une garantie cryptographique.

Cette persistance représente un compromis volontaire entre sécurité et confort
d'utilisation. Une personne disposant d'un accès suffisamment privilégié aux
données locales de l'application, ainsi qu'au code permettant de les interpréter,
pourrait théoriquement récupérer une session persistée.

La suppression de cette persistance imposerait à l'utilisateur de se reconnecter
après chaque redémarrage de l'application, ce qui n'est pas le comportement
retenu pour le build public.

## Données pouvant rester enregistrées

Pour restaurer l'expérience utilisateur, ReDeFin peut conserver localement :

- l'URL du serveur Jellyfin ;
- le `userId` et le nom du profil ;
- le tag d'image du profil ;
- la liste des serveurs déjà utilisés ;
- la dernière sélection de profil ;
- certaines préférences UI et de lecture ;
- un `DeviceId` ReDeFin aléatoire et stable, généré au premier lancement. Cet
  identifiant n'est dérivé ni d'une adresse MAC, ni d'un numéro de série, ni d'un
  `accountId` Freebox et ne constitue pas un secret ;
- les informations nécessaires à la restauration d'une session Jellyfin lorsque
  cette fonctionnalité est active.

Les préférences générales sont filtrées afin d'exclure les clés sensibles telles
que `token`, `accessToken`, `apiKey`, `Authorization`, `Cookie`, `password`,
`secret` ou `PlaySessionId`.

Les données d'authentification persistantes doivent rester isolées du stockage
des préférences générales.

## Réseau

ReDeFin communique directement avec le serveur Jellyfin choisi par l'utilisateur.

- Les secrets d'authentification sont refusés en HTTP vers un serveur WAN.
- HTTP reste autorisé pour les serveurs considérés locaux/LAN.
- Pour un accès distant, HTTPS est fortement recommandé.
- Les appels REST Jellyfin utilisent un header `Authorization`.
- Les téléchargements de sous-titres texte SRT/VTT utilisent également
  `Authorization` et n'ajoutent pas le token dans la query de l'URL.
- Les redirections authentifiées sont limitées à la même origine par le bridge.
- Les réponses réseau sensibles ou anormalement volumineuses doivent être
  rejetées ou bornées avant traitement lorsque cela est techniquement possible.

Certaines URLs de lecture fournies directement à QtMultimedia peuvent dépendre
des contraintes du runtime Freebox, de QtMultimedia 5.15 et de Jellyfin. Dans
certains cas, ces URLs peuvent contenir des informations d'authentification
nécessaires à la lecture.

ReDeFin ne journalise pas volontairement ces URLs complètes dans le build public.

Les éventuelles traces générées en dehors du code applicatif ReDeFin, par exemple
par le firmware Freebox, QtMultimedia, Jellyfin, FFmpeg ou un reverse proxy,
dépendent des composants concernés et de leur configuration.

## Logs applicatifs

Le build public verrouille les logs applicatifs de diagnostic.

Les logs applicatifs de production ne doivent jamais volontairement exposer :

- un token ou jeton d'authentification ;
- un header `Authorization`, `Cookie` ou équivalent ;
- une URL serveur complète ;
- un domaine externe identifiable ;
- une adresse IPv4 ou IPv6 ;
- des paramètres HTTP sensibles ;
- un `userId`, `itemId`, `PlaySessionId`, `MediaSourceId` ou identifiant similaire
  sous sa forme brute ;
- un chemin de média ou de serveur ;
- un nom de fichier média sensible ;
- le texte saisi dans une recherche ;
- une réponse `PlaybackInfo` complète ;
- le contenu brut d'une réponse réseau contenant des informations privées.

Lorsqu'un build développeur active les diagnostics, ReDeFin doit anonymiser ou
remplacer ces données avant journalisation.

Les identifiants peuvent notamment être remplacés par des alias temporaires de
session tels que `[user-1]`, `[item-2]`, `[source-1]` ou `[server-1]`.

## Logs externes et diagnostics

ReDeFin ne doit pas exporter automatiquement des logs Jellyfin, FFmpeg,
reverse-proxy, QtMultimedia ou système bruts.

Ces logs externes peuvent contenir :

- des URLs complètes ;
- des paramètres d'authentification ;
- des chemins de médias ;
- des noms de fichiers ;
- des adresses IP ;
- des noms de domaine ;
- des identifiants Jellyfin ;
- des informations détaillées sur les fichiers lus ou transcodés.

Lorsqu'un diagnostic est demandé à un utilisateur ou à un bêta-testeur, les logs
doivent être vérifiés et anonymisés avant publication ou partage public.

Aucun ZIP, archive ou capture de diagnostic ne doit être ajouté volontairement au
dépôt GitHub public sans contrôle préalable.

## Télémétrie

ReDeFin n'ajoute pas de télémétrie applicative, de suivi publicitaire ou de
service d'analytics dans les fichiers couverts par cette politique.

Les communications nécessaires au fonctionnement de Jellyfin restent soumises à
la configuration du serveur de l'utilisateur.

Le serveur Jellyfin, son reverse proxy, le fournisseur DNS, le réseau local ou
d'autres composants externes peuvent disposer de leurs propres journaux et
politiques de conservation.

## Suppression locale

La fonction « oublier cet appareil » doit supprimer les données locales associées
à la connexion, notamment :

- les profils mémorisés ;
- les informations de session persistantes ;
- les jetons encore présents en mémoire ;
- les préférences associées lorsque leur conservation n'est plus nécessaire ;
- les références serveur concernées.

Une déconnexion simple peut supprimer la session active sans nécessairement
effacer l'ensemble des préférences non sensibles ou la configuration du serveur.
Le `DeviceId` d'installation est conservé lors d'une déconnexion ou d'un oubli de
profil afin que Jellyfin continue d'identifier cette installation comme le même
appareil. Il disparaît avec les données de l'application / sa réinstallation.

Lors de la migration depuis les anciennes versions qui utilisaient un `DeviceId`
commun à toutes les Freebox, ReDeFin supprime localement les sessions persistantes
existantes. Cette migration peut demander une nouvelle authentification unique afin
que Jellyfin crée ensuite la session avec le nouvel identifiant propre à l'appareil.

Lorsque ReDeFin évolue vers un nouveau format de stockage, les anciennes clés
d'authentification devenues inutiles doivent être supprimées ou migrées afin
d'éviter de conserver plusieurs copies d'un même secret.

## Sécurité du stockage local

Les données locales de ReDeFin sont stockées dans les mécanismes disponibles sur
la plateforme Freebox.

ReDeFin applique les principes suivants :

- ne pas enregistrer un token en clair dans les préférences générales ;
- limiter le nombre de copies persistantes des secrets ;
- isoler les informations de session du reste des préférences ;
- supprimer les anciens formats de stockage devenus inutiles ;
- ne jamais supposer qu'une valeur stockée localement est inaccessible au système
  ou à un utilisateur disposant de privilèges suffisants ;
- ne pas présenter l'obfuscation locale comme un chiffrement fort.

Les limitations liées au stockage fourni par l'OS, au SDK Freebox ou au matériel
ne peuvent pas toutes être compensées proprement par une application QML/JS sans
dépendance cryptographique adaptée.

## Publication GitHub

Avant une publication GitHub, le dépôt doit être contrôlé afin d'éviter la
publication accidentelle de :

- tokens ;
- mots de passe ;
- fichiers `.env` ;
- fichiers `secrets`, `credentials`, `tokens` ou équivalents ;
- logs ;
- dumps ;
- captures réseau ;
- archives ZIP de diagnostic ;
- fichiers contenant des URLs privées, adresses IP ou chemins internes ;
- configurations locales de développement.

Le `.gitignore` constitue une protection supplémentaire mais ne remplace pas le
contrôle du contenu réellement versionné.

L'historique Git doit également être contrôlé lorsqu'un secret a pu être commité
dans une ancienne révision, car l'ajout ultérieur d'une règle `.gitignore` ne
supprime pas les données déjà présentes dans l'historique.

## Publication FreeStore

Avant une publication FreeStore :

- le package final doit être inspecté indépendamment du dépôt Git ;
- aucun fichier sensible ignoré par Git ne doit être inclus accidentellement ;
- les logs de diagnostic doivent rester verrouillés par défaut ;
- les permissions Freebox demandées doivent rester limitées au strict nécessaire ;
- aucune donnée de développement ou de bêta-test ne doit être intégrée au package ;
- la politique de confidentialité doit correspondre au comportement réel du
  build publié.

## Limites de sécurité

ReDeFin vise à réduire les risques raisonnablement contrôlables au niveau de
l'application.

Certaines protections dépendent cependant du système Freebox, de QtMultimedia
5.15, du serveur Jellyfin ou de l'infrastructure réseau de l'utilisateur.

Ces limitations peuvent notamment concerner :

- la protection physique du stockage local ;
- les journaux internes du système ;
- les journaux réseau du serveur Jellyfin ou d'un reverse proxy ;
- certaines URLs de lecture remises directement à QtMultimedia ;
- les mécanismes de stockage sécurisés proposés ou non par la plateforme.

Ces risques ne peuvent pas toujours être supprimés sans dégrader fortement la
compatibilité ou l'expérience utilisateur.

## Principe retenu

Le build public de ReDeFin cherche donc un équilibre entre :

- **confort**, avec restauration automatique de la session lorsque cela est
  possible ;
- **confidentialité**, en évitant la journalisation et la duplication des secrets ;
- **sécurité réseau**, en refusant l'envoi de secrets vers un serveur WAN en HTTP ;
- **transparence**, en indiquant clairement que le stockage persistant disponible
  sur Freebox n'est pas assimilé à un coffre cryptographique fort ;
- **compatibilité**, en restant compatible avec QtQuick 2.15, QtMultimedia 5.15
  et les contraintes des Freebox ciblées.
