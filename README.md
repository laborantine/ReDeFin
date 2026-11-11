<!-- README ReDeFin : logo et captures issus du projet. -->
<a id="readme-top"></a>

<div align="center">

<a href="https://github.com/laborantine/ReDeFin">
  <img src="https://github.com/user-attachments/assets/c14346df-2e99-482b-9c6d-d064583890bd" alt="Logo ReDeFin" width="230" />
</a>

<h1>ReDeFin</h1>

<p>Votre bibliothèque Jellyfin sur Freebox Révolution et Devialet.</p>

<p>
  Un client Jellyfin non officiel, conçu pour retrouver ses films et ses séries sur la télévision.
</p>

<p>
  <a href="#installation"><img src="https://img.shields.io/badge/Version-1.0%20stable-228B5A?style=flat-square" alt="Version 1.0 stable" /></a>
  <a href="#beta"><img src="https://img.shields.io/badge/B%C3%AAta-Candidatures%20ouvertes-C37622?style=flat-square" alt="Candidatures bêta ouvertes" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/laborantine/ReDeFin?style=flat-square&amp;label=Licence&amp;color=4E7D52" alt="Licence du projet" /></a>
  <a href="https://github.com/laborantine/ReDeFin/stargazers"><img src="https://img.shields.io/github/stars/laborantine/ReDeFin?style=flat-square&amp;color=4475D1" alt="Étoiles GitHub" /></a>
  <a href="https://github.com/laborantine/ReDeFin/issues"><img src="https://img.shields.io/github/issues/laborantine/ReDeFin?style=flat-square&amp;color=4475D1" alt="Issues GitHub" /></a>
</p>

<p>
  <a href="https://jellyfin.org/"><img src="https://cdn.simpleicons.org/jellyfin/A98CEE" alt="Jellyfin" height="25" /></a>&nbsp;&nbsp;&nbsp;
  <a href="https://www.free.fr/freebox/"><img src="https://upload.wikimedia.org/wikipedia/commons/8/8a/Freebox_%28logo%29.svg" alt="Freebox" height="25" /></a>&nbsp;&nbsp;&nbsp;
  <a href="https://www.qt.io/"><img src="https://cdn.simpleicons.org/qt/41CD52" alt="Qt" height="25" /></a>&nbsp;&nbsp;&nbsp;
  <a href="https://developer.mozilla.org/fr/docs/Web/JavaScript"><img src="https://cdn.simpleicons.org/javascript/F7DF1E" alt="JavaScript" height="25" /></a>&nbsp;&nbsp;&nbsp;
  <a href="https://openai.com/"><img src="https://upload.wikimedia.org/wikipedia/commons/6/66/OpenAI_logo_2025_%28symbol%29.svg" alt="OpenAI" height="25" /></a>
</p>

</div>

<a href="docs/screenshots/ReDeFin_02_Accueil_1066x600.jpg">
  <img src="docs/screenshots/ReDeFin_02_Accueil_1066x600.jpg" width="100%" alt="Écran d'accueil de ReDeFin" />
</a>
<p align="center"><sub>L'accueil de ReDeFin, tel qu'il apparaît sur Freebox. Cliquez sur l'image pour l'agrandir.</sub></p>

<p align="center">
  <a href="#installation"><img src="assets/readme-icons/download.svg" width="20" height="20" alt="" /> Installer ReDeFin</a>
  &nbsp;·&nbsp;
  <a href="https://github.com/laborantine/ReDeFin/issues/new?labels=bug"><img src="assets/readme-icons/bug.svg" width="20" height="20" alt="" /> Signaler un bug</a>
  &nbsp;·&nbsp;
  <a href="https://github.com/laborantine/ReDeFin/issues/new?labels=enhancement"><img src="assets/readme-icons/idea.svg" width="20" height="20" alt="" /> Proposer une idée</a>
  &nbsp;·&nbsp;
  <a href="#beta"><img src="assets/readme-icons/people.svg" width="20" height="20" alt="" /> Rejoindre la bêta</a>
</p>

<details>
<summary>Parcourir le README</summary>

- [À propos de ReDeFin](#a-propos)
- [Ce que permet ReDeFin](#fonctionnalites)
- [L'application en images](#captures)
- [Freebox compatibles](#compatibilite)
- [Installer la version stable](#installation)
- [Les prochaines étapes](#roadmap)
- [Participer à la bêta et consulter les places disponibles](#beta)
- [Participer au projet ou signaler un problème](#contribuer)
- [Comment ReDeFin est développé](#technologies)
- [Licence](#licence)
- [Contact et remerciements](#contact)

</details>

---

<a id="a-propos"></a>
## À propos de ReDeFin

ReDeFin est né de l'envie d'utiliser Jellyfin sur les Players Freebox Révolution et Devialet, avec une interface agréable à parcourir depuis son canapé, qui n'existait pas encore.

Au départ, le projet était un portage de Sailfin, un client Jellyfin sur Sailfish OS (https://github.com/heartfin/harbour-sailfin). Mais ce dernier a été conçu en C++ et certains modules QML (Exemple : Silica) étaient à réécrire pour l'adapter sur Freebox. Le travail était autant chargé pour l'adapter sur Freebox qu'écrire un projet from scratch, la deuxième option a fini par être choisie.

En s'inspirant de l'interface et des fonctionnalités du client officiel Jellyfin for Android TV entre juin 2025 et décembre 2025, l'objectif a été de générer un livrable afin que les beta-testeurs potentiels puissent tester la toute première version beta, qui est sortie le 21 Décembre 2025.

S'est ensuite échelonné sur 10 mois, plusieurs builds qui auront apporté corrections des bugs, d'interface, ainsi que des ajouts de fonctionnalités. Ce qui a permis d'avoir la première version stable en Octobre 2026, optimisée pour la Freebox Révolution et Devialet.

Le but est de se rapprocher de l'expérience proposée par le client officiel Jellyfin sur Android TV, tout en tenant compte des possibilités et des limites des Freebox. Vous gardez votre serveur Jellyfin et vos propres fichiers : ReDeFin sert simplement à les retrouver et à les lire sur votre télévision.

ReDeFin est un projet indépendant et open source. Il n'est pas développé officiellement par Jellyfin ou Free.

<a id="fonctionnalites"></a>
## <img src="assets/readme-icons/play.svg" width="25" height="25" alt="" /> Ce que permet ReDeFin

Avec la version 1.0 stable, vous pouvez :

#### Médiathèque et navigation

- Accès aux bibliothèques de films, séries et collections Jellyfin.
- Navigation dans les saisons, épisodes, collections et dossiers de la médiathèque.
- Prise en charge des vidéos et photos personnelles, avec une visionneuse adaptée aux photos.
- Recherche de films, séries, épisodes, collections et dossiers.
- Fiches détaillées avec synopsis, genres, informations techniques et illustrations.
- Consultation de la distribution, des équipes de production et des fiches des personnes.
- Suggestions de contenus similaires et accès aux épisodes suivants.

#### Lecture multimédia

- Lecture en Direct Play, Direct Stream, remuxage ou transcodage selon les capacités de la Freebox et du serveur Jellyfin.
- Sélection des pistes audio et des sous-titres disponibles.
- Réglage de la qualité vidéo, de la vitesse de lecture et du zoom.
- Reprise de la lecture à l'endroit où elle s'était arrêtée.
- Lecture successive des épisodes et possibilité de lecture aléatoire.
- Navigation entre les chapitres et saut des introductions lorsqu'ils sont disponibles.
- Suivi de la progression de lecture avec Jellyfin.

#### Profils et expérience utilisateur

- Connexion à un serveur Jellyfin et utilisation de plusieurs profils.
- Gestion des favoris et des contenus vus ou non vus.
- Navigation adaptée aux Freebox Révolution et Devialet, avec une attention particulière portée à leurs capacités matérielles.


Si vous découvrez Jellyfin, sa <a href="https://jellyfin.org/docs/"><img src="assets/readme-icons/book.svg" width="20" height="20" alt="" /> documentation officielle</a> explique comment préparer et organiser votre médiathèque.

<a id="captures"></a>
## <img src="assets/readme-icons/screen.svg" width="25" height="25" alt="" /> L'application en images

<table>
  <tr>
    <td width="50%" align="center" valign="top">
      <a href="docs/screenshots/ReDeFin_01_Profils_1066x600.jpg"><img src="docs/screenshots/ReDeFin_01_Profils_1066x600.jpg" width="100%" alt="Sélection des profils dans ReDeFin" /></a>
      <br /><sub>Sélection des profils</sub>
    </td>
    <td width="50%" align="center" valign="top">
      <a href="docs/screenshots/ReDeFin_03_Collection_1066x600.jpg"><img src="docs/screenshots/ReDeFin_03_Collection_1066x600.jpg" width="100%" alt="Page des collections dans ReDeFin" /></a>
      <br /><sub>Collections</sub>
    </td>
  </tr>
</table>

<a id="compatibilite"></a>
## <img src="assets/readme-icons/screen.svg" width="25" height="25" alt="" /> Freebox compatibles

Pour utiliser ReDeFin, il vous faut un serveur Jellyfin accessible depuis votre Freebox et l'un de ces Players :

<table>
  <tr>
    <td width="50%" align="center" valign="top">
      Freebox Révolution<br /><br />
      <a href="https://github.com/user-attachments/assets/691c2ed2-626e-4702-8277-9750ef365264"><img src="https://github.com/user-attachments/assets/691c2ed2-626e-4702-8277-9750ef365264" width="100%" alt="Freebox Révolution" /></a>
    </td>
    <td width="50%" align="center" valign="top">
      Freebox Delta avec Player Devialet<br /><br />
      <a href="https://github.com/user-attachments/assets/ee7d6788-fa02-4e52-aed8-ad6201c4454c"><img src="https://github.com/user-attachments/assets/ee7d6788-fa02-4e52-aed8-ad6201c4454c" width="100%" alt="Player Freebox Devialet" /></a>
    </td>
  </tr>
</table>

La lecture dépend aussi du format de vos fichiers et des capacités du Player. Si une vidéo doit être transcodée, c'est votre serveur Jellyfin qui s'en charge.

---

<a id="installation"></a>
## <img src="assets/readme-icons/download.svg" width="25" height="25" alt="" /> Installer la version stable

<p>
  <img src="https://img.shields.io/badge/Version-1.0%20stable-228B5A?style=flat-square" alt="Version stable 1.0" />
  <img src="https://img.shields.io/badge/Disponible%20depuis-28%20octobre%202026-4475D1?style=flat-square" alt="Disponible depuis le 28 octobre 2026" />
</p>

ReDeFin 1.0 est disponible sur le Free Store depuis le 28 octobre 2026. Si votre Player y a accès, vous pouvez l'installer sans vous inscrire au programme bêta.

1. Ouvrez le Free Store sur votre Player Freebox.
2. Recherchez `ReDeFin` et installez l'application.
3. Lancez ReDeFin et connectez-vous à votre serveur Jellyfin.

### Et si vous utilisez un Player Devialet sans abonnement Free ?

L'installation depuis le Free Store nécessite un abonnement donnant accès à ce service. Si vous avez un Player Devialet sans abonnement associé, vous pouvez [me contacter](#contact). Il existe des possibilités de test en dehors du Free Store, mais elles dépendent de votre configuration.

<details>
<summary>Utiliser le code source avec le SDK Freebox</summary>

Le code de ReDeFin est disponible sur ce dépôt. Si vous disposez d'un environnement de développement adapté, vous pouvez aussi le lancer avec le SDK QML Freebox.

- [Consulter le code source](https://github.com/laborantine/ReDeFin)
- [Documentation du SDK Freebox](https://dev.freebox.fr/sdk/libfbxqml/)

Cette possibilité s'adresse plutôt aux développeurs. Pour une installation classique, le Free Store reste la voie la plus simple.

</details>

<a id="roadmap"></a>
## <img src="assets/readme-icons/issues.svg" width="25" height="25" alt="" /> Les prochaines étapes

ReDeFin a franchi une première étape avec la sortie de sa version 1.0 stable. Voici ce qui est prévu à l'avenir.

### À l'étude pour les prochaines versions

#### Nouvelles fonctionnalités

- [ ] Prise en charge des bibliothèques musicales avec une interface dédiée aux artistes, albums et morceaux.
- [ ] Accès aux chaînes TV configurées dans Jellyfin, notamment via des playlists M3U.
- [ ] Davantage de possibilités de personnalisation de l'interface et des paramètres.
- [ ] Consultation et lecture des bandes-annonces des films et séries.
- [ ] Amélioration de l'organisation et de la navigation dans les médiathèques.

#### Pistes de réflexion à plus long terme

- [ ] Expérimentation de commandes vocales, notamment avec Alexa.
- [ ] Identification plus précise des voix françaises disponibles pour les films et séries.
- [ ] Réflexion sur de nouvelles évolutions de l'interface et de son ergonomie.

Ces fonctionnalités sont à l'étude et ne sont pas garanties. Leur intégration dépendra de leur faisabilité, des possibilités offertes par Jellyfin et les Freebox, ainsi que des retours des utilisateurs.

Pour suivre les propositions et leur avancement, consultez les [issues GitHub](https://github.com/laborantine/ReDeFin/issues).

Ce sont les pistes de travail actuelles, pas des dates de sortie promises. Les idées et les problèmes signalés sont suivis dans les [Issues GitHub](https://github.com/laborantine/ReDeFin/issues).

<p>
  <a href="https://github.com/laborantine/ReDeFin/issues"><img src="assets/readme-icons/issues.svg" width="20" height="20" alt="" /> Suivre les demandes et les problèmes connus</a>
</p>

<a id="beta"></a>
## <img src="assets/readme-icons/people.svg" width="25" height="25" alt="" /> Participer à la bêta

Même si ReDeFin 1.0 est maintenant disponible en version stable, ReDeFin continue d'accueillir des bêta-testeurs pour essayer les prochaines nouveautés avant leur sortie.

Vous n'avez pas besoin de vous inscrire pour utiliser la version stable. Les candidatures concernent seulement les versions de test.

### Places disponibles

<p>
  <img src="https://img.shields.io/badge/Places-110%20occup%C3%A9es%20sur%20160%20%E2%80%94%2050%20restantes-C37622?style=flat-square" alt="Programme bêta : 110 places occupées sur 160, 50 places restantes" />
</p>

<table>
  <tr>
    <td align="center" valign="top" width="50%">
      Freebox Devialet<br /><br />
      <img src="https://img.shields.io/badge/Devialet-75%2F80%20occup%C3%A9es-DC2626?style=flat-square" alt="Bêta Devialet : 75 places occupées sur 80" /><br />
      <sub>5 places restantes</sub>
    </td>
    <td align="center" valign="top" width="50%">
      Freebox Révolution<br /><br />
      <img src="https://img.shields.io/badge/R%C3%A9volution-35%2F80%20occup%C3%A9es-2B9348?style=flat-square" alt="Bêta Révolution : 35 places occupées sur 80" /><br />
      <sub>45 places restantes</sub>
    </td>
  </tr>
</table>

<sub>Ces chiffres sont mis à jour manuellement. Le nombre de places peut donc avoir changé depuis la dernière modification du README.</sub>

### Comment s'inscrire ?

Si vous souhaitez participer, envoyez-moi un mail à [application.redefin@proton.me](mailto:application.redefin@proton.me) en précisant votre numéro d'abonné Freebox (il commence généralement par `fbxXXX`) et le modèle de votre Player : Révolution ou Devialet.

Vous trouverez votre numéro d'abonné dans votre espace client Freebox. Pensez à indiquer dans votre message que vous souhaitez rejoindre la bêta de ReDeFin.

Je vous répondrai pour confirmer la prise en compte de votre candidature et, si une place vous est attribuée, l'enregistrement de votre numéro d'abonné dans la liste des bêta-testeurs. Je vous préciserai alors comment accéder à la version de test.

Il suffit de communiquer votre numéro d'abonné. N'envoyez pas votre mot de passe Freebox ni vos identifiants Jellyfin.

---

<a id="contribuer"></a>
## <img src="assets/readme-icons/people.svg" width="25" height="25" alt="" /> Participer au projet

Un bug, une suggestion ou simplement un retour après utilisation ? Tout cela m'aide à faire évoluer ReDeFin. Si vous avez envie de contribuer au code, les pull requests sont également les bienvenues.

<table>
  <tr>
    <td align="center" width="50%"><a href="https://github.com/laborantine/ReDeFin/issues/new?labels=bug"><img src="assets/readme-icons/bug.svg" width="26" height="26" alt=""/><br />Signaler un bug</a></td>
    <td align="center" width="50%"><a href="https://github.com/laborantine/ReDeFin/issues/new?labels=enhancement"><img src="assets/readme-icons/idea.svg" width="26" height="26" alt=""/><br />Suggérer une fonctionnalité</a></td>
  </tr>
  <tr>
    <td align="center"><a href="https://github.com/laborantine/ReDeFin/fork"><img src="assets/readme-icons/fork.svg" width="26" height="26" alt=""/><br />Forker le dépôt</a></td>
    <td align="center"><a href="https://github.com/laborantine/ReDeFin/pulls"><img src="assets/readme-icons/pull-request.svg" width="26" height="26" alt=""/><br />Proposer une pull request</a></td>
  </tr>
</table>

Avant de créer un ticket, jetez un œil aux [problèmes déjà signalés](https://github.com/laborantine/ReDeFin/issues). Pour un bug, précisez si possible votre modèle de Freebox, la version de ReDeFin et ce qui s'est passé. Si vous pouvez expliquer comment reproduire le souci, c'est encore mieux.

<p align="center">
  <a href="https://github.com/laborantine/ReDeFin/stargazers"><img src="assets/readme-icons/star.svg" width="22" height="22" alt="" /> Ajouter une étoile au dépôt</a>
</p>

<details>
<summary>Voir les contributeurs</summary>

<a href="https://github.com/laborantine/ReDeFin/graphs/contributors"><img src="https://contrib.rocks/image?repo=laborantine/ReDeFin" alt="Contributeurs du dépôt ReDeFin" /></a>

</details>

<a id="technologies"></a>
## Comment ReDeFin est développé

<p>
  <a href="https://www.qt.io/"><img src="https://img.shields.io/badge/QtQuick-2.15-202932?style=flat-square&amp;logo=qt&amp;logoColor=41CD52" alt="QtQuick 2.15" /></a>
  <a href="https://doc.qt.io/qt-5/qtmultimedia-index.html"><img src="https://img.shields.io/badge/QtMultimedia-5.15-202932?style=flat-square&amp;logo=qt&amp;logoColor=41CD52" alt="QtMultimedia 5.15" /></a>
  <a href="https://developer.mozilla.org/fr/docs/Web/JavaScript"><img src="https://img.shields.io/badge/JavaScript-QML-202932?style=flat-square&amp;logo=javascript&amp;logoColor=F7DF1E" alt="JavaScript et QML" /></a>
  <a href="https://jellyfin.org/"><img src="https://img.shields.io/badge/API-Jellyfin-202932?style=flat-square&amp;logo=jellyfin&amp;logoColor=A98CEE" alt="API Jellyfin" /></a>
  <a href="https://dev.freebox.fr/sdk/libfbxqml/"><img src="https://img.shields.io/badge/SDK-Freebox-202932?style=flat-square" alt="SDK Freebox" /></a>
  <a href="https://chatgpt.com/"><img src="https://img.shields.io/badge/ChatGPT-OpenAI-202932?style=flat-square&amp;logo=openai&amp;logoColor=white" alt="ChatGPT OpenAI" /></a>
</p>

J'ai commencé à mener des pistes de réflexion dès fin 2024 en m'appuyant sur ChatGPT. En avril 2025 le projet débute réellement pour écrire et faire évoluer le code. Le projet possède une orientation de développement définie sur bien des points. L'application est testée sur la Freebox Devialet et son fonctionnement est adapté aux contraintes de ces appareils. Les retours des utilisateurs aident aussi à décider des corrections et des améliorations à apporter.

ReDeFin utilise QML et JavaScript avec QtQuick et QtMultimedia. L'optimisation est particulièrement importante sur la Freebox Révolution, dont les ressources sont plus limitées.

<details>
<summary>Modèles ChatGPT utilisés au fil du projet</summary>

Travaux préliminaires (2024 à mars 2025) :

- GPT-3.5
- GPT-4
- GPT-4o

Travaux principaux (avril 2025 à aujourd'hui) :

- GPT-4.5
- GPT-5
- GPT-5.1
- GPT-5.2
- GPT-5.4
- GPT-5.5
- GPT-5.6 Sol
- GPT 6.1 Sol

</details>

---

<a id="licence"></a>
## <img src="assets/readme-icons/shield.svg" width="25" height="25" alt="" /> Licence

<a href="LICENSE"><img src="https://img.shields.io/badge/GNU-GPLv3-436837?style=flat-square&amp;logo=gnu&amp;logoColor=white" alt="Licence GNU GPL version 3" /></a>

Le code de ReDeFin est publié sous licence GNU GPL version 3. Vous pouvez consulter le fichier [LICENSE](LICENSE) pour en connaître les conditions.

<a id="contact"></a>
## <img src="assets/readme-icons/mail.svg" width="25" height="25" alt="" /> Contact et remerciements

<p>
  <a href="mailto:application.redefin@proton.me"><img src="https://img.shields.io/badge/Proton-Mail-6D4AFF?style=flat-square&amp;logo=protonmail&amp;logoColor=white" alt="Contacter ReDeFin par Proton Mail" /></a>
  <a href="https://github.com/laborantine/ReDeFin/issues"><img src="https://img.shields.io/badge/GitHub-Issues-252B37?style=flat-square&amp;logo=github&amp;logoColor=white" alt="GitHub Issues" /></a>
</p>

Vous pouvez me contacter par mail à [application.redefin@proton.me](mailto:application.redefin@proton.me) ou ouvrir une [issue sur GitHub](https://github.com/laborantine/ReDeFin/issues).

Merci à l'équipe de Free, aux bêta-testeurs et à toutes les personnes qui prennent le temps de signaler un problème, de proposer une idée ou de contribuer au projet. Merci également à OpenAI, dont les outils m'accompagnent dans le développement de ReDeFin.


### Évolution des étoiles GitHub

[![Star History Chart](https://api.star-history.com/svg?repos=laborantine/ReDeFin&type=Date)](https://www.star-history.com/)


<p align="center"><a href="https://ko-fi.com/B0B01NEJ0U"><img src="https://ko-fi.com/img/githubbutton_sm.svg" alt="Soutenir ReDeFin sur Ko-fi" /></a></p>

<p align="center"><a href="#readme-top">↑ Retour en haut</a></p>

<!-- Les logos des services renvoient aux technologies utilisées, sans suggérer de partenariat officiel. -->
