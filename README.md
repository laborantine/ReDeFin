<a id="readme-top"></a>

<div align="center">

<a href="https://github.com/laborantine/ReDeFin">
  <img src="https://github.com/user-attachments/assets/c14346df-2e99-482b-9c6d-d064583890bd" alt="Logo officiel ReDeFin" width="320" />
</a>

<h1>ReDeFin</h1>

<h3>Un client Jellyfin non officiel pour lire votre bibliothèque sur Freebox</h3>

<p>ReDeFin est un client non officiel Jellyfin pensé spécialement pour les Freebox Player (Révolution / Devialet).</p>

<p>Son objectif : Profiter de votre bibliothèque comme sur une grande plateforme de streaming avec votre serveur, vos fichiers, votre Freebox.</p>

<p>
  <a href="https://jellyfin.org/" title="Jellyfin"><img src="https://cdn.simpleicons.org/jellyfin/A98CEE" alt="Jellyfin" height="25" /></a>
  &nbsp;&nbsp;&nbsp;
  <a href="https://www.qt.io/" title="Qt"><img src="https://cdn.simpleicons.org/qt/41CD52" alt="Qt" height="25" /></a>
  &nbsp;&nbsp;&nbsp;
  <a href="https://developer.mozilla.org/fr/docs/Web/JavaScript" title="JavaScript"><img src="https://cdn.simpleicons.org/javascript/F7DF1E" alt="JavaScript" height="25" /></a>
  &nbsp;&nbsp;&nbsp;
  <a href="https://www.free.fr/freebox/" title="Freebox"><img src="https://upload.wikimedia.org/wikipedia/commons/8/8a/Freebox_%28logo%29.svg" alt="Freebox" height="25" /></a>
</p>

<p>
  <a href="https://github.com/laborantine/ReDeFin"><strong>Voir la documentation</strong></a>
  &nbsp; · &nbsp;
  <a href="https://github.com/laborantine/ReDeFin/issues/new?labels=bug&amp;template=bug-report---.md">Rapporter un bug</a>
  &nbsp; · &nbsp;
  <a href="https://github.com/laborantine/ReDeFin/issues/new?labels=enhancement&amp;template=feature-request---.md">Suggérer une nouvelle fonctionnalité</a>
</p>

<p>
  <a href="https://github.com/laborantine/ReDeFin/stargazers"><img src="https://img.shields.io/github/stars/laborantine/ReDeFin?style=flat-square&amp;color=2563eb&amp;label=Stars" alt="Stargazers" /></a>
  <a href="https://github.com/laborantine/ReDeFin/network/members"><img src="https://img.shields.io/github/forks/laborantine/ReDeFin?style=flat-square&amp;color=2563eb&amp;label=Forks" alt="Forks" /></a>
  <a href="https://github.com/laborantine/ReDeFin/issues"><img src="https://img.shields.io/github/issues/laborantine/ReDeFin?style=flat-square&amp;color=2563eb&amp;label=Issues" alt="Issues" /></a>
  <a href="https://github.com/laborantine/ReDeFin/graphs/contributors"><img src="https://img.shields.io/github/contributors/laborantine/ReDeFin?style=flat-square&amp;color=2563eb&amp;label=Contributeurs" alt="Contributeurs" /></a>
  <a href="https://github.com/laborantine/ReDeFin/blob/main/LICENSE"><img src="https://img.shields.io/github/license/laborantine/ReDeFin?style=flat-square&amp;color=2563eb&amp;label=Licence" alt="Licence" /></a>
</p>

</div>

<!-- Une vraie capture ReDeFin ouvre le README, sans illustration fictive. -->
<a href="docs/screenshots/ReDeFin_02_Accueil_1066x600.jpg">
  <img src="docs/screenshots/ReDeFin_02_Accueil_1066x600.jpg" alt="Capture d'écran de l'accueil ReDeFin" width="100%" />
</a>

<p align="center"><sub>Accueil ReDeFin · Capture d'écran de l'application</sub></p>

<div align="center">
  <a href="#captures">Captures</a> &nbsp;·&nbsp;
  <a href="#about-this-project">Le projet</a> &nbsp;·&nbsp;
  <a href="#getting-started">Introduction</a> &nbsp;·&nbsp;
  <a href="#prerequisites">Freebox compatibles</a> &nbsp;·&nbsp;
  <a href="#installation">Installation</a> &nbsp;·&nbsp;
  <a href="#roadmap">Roadmap</a> &nbsp;·&nbsp;
  <a href="#contributing">Contribuer</a>
</div>

<br />

<a id="captures"></a>
## L'application en images

<table>
  <tr>
    <td align="center" width="50%" valign="top">
      <a href="docs/screenshots/ReDeFin_01_Profils_1066x600.jpg">
        <img src="docs/screenshots/ReDeFin_01_Profils_1066x600.jpg" alt="Capture d'écran : sélection des profils ReDeFin" width="100%" />
      </a>
      <br /><sub><b>01 / Profils</b></sub>
    </td>
    <td align="center" width="50%" valign="top">
      <a href="docs/screenshots/ReDeFin_03_Collection_1066x600.jpg">
        <img src="docs/screenshots/ReDeFin_03_Collection_1066x600.jpg" alt="Capture d'écran : collection Éclipse dans ReDeFin" width="100%" />
      </a>
      <br /><sub><b>02 / Collection</b></sub>
    </td>
  </tr>
</table>

<details>
<summary><strong>Table des matières</strong></summary>

- [L'application en images](#captures)
- [A propos de ce projet](#about-this-project)
- [Fabriqué avec](#built-with)
- [Introduction](#getting-started)
- [Prérequis](#prerequisites)
- [Installation](#installation)
- [Usage](#usage)
- [Roadmap](#roadmap)
- [Contributeurs](#contributing)
- [Licence](#license)
- [Contact](#contact)
- [Remerciements](#acknowledgments)

</details>

---

<a id="about-this-project"></a>
## A propos de ce projet

ReDeFin est un client Jellyfin NON OFFICIEL codé en QML et JavaScript, compatible Freebox Revolution et Freebox Delta (Devialet).

L'objectif souhaité est de se rapprocher visuellement et fonctionnellement de ce que le client officiel Android TV est capable de faire.

<a id="built-with"></a>
### Fabriqué avec

<p>
  <a href="https://chatgpt.com/fr-FR"><img src="https://img.shields.io/badge/ChatGPT-OpenAI-202932?style=flat-square&amp;logo=openai&amp;logoColor=white" alt="ChatGPT OpenAI" /></a>
  <a href="https://www.qt.io/"><img src="https://img.shields.io/badge/QtQuick-2.15-202932?style=flat-square&amp;logo=qt&amp;logoColor=41CD52" alt="QtQuick 2.15" /></a>
  <a href="https://developer.mozilla.org/fr/docs/Web/JavaScript"><img src="https://img.shields.io/badge/JavaScript-QML-202932?style=flat-square&amp;logo=javascript&amp;logoColor=F7DF1E" alt="JavaScript" /></a>
</p>

Ce projet a été intégralement fabriqué à partir de ChatGPT depuis 2024. Il a été fabriqué à partir des modèles de langages suivants :

<details>
<summary><strong>Travaux préliminaires (2024 - mars 2025) :</strong></summary>

- GPT-3.5
- GPT-4
- GPT-4o

</details>

<details>
<summary><strong>Travaux principaux (avril 2025 - maintenant) :</strong></summary>

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

<a id="getting-started"></a>
## Introduction

![Places bêta](https://img.shields.io/badge/Places-110%20occup%C3%A9es%20sur%20160%20%E2%80%94%2050%20restantes-orange?style=flat-square)

Le projet est actuellement en phase bêta fermé.

<table>
  <tr>
    <td width="50%" valign="top">
      <strong>Freebox Devialet</strong>
      <p>Disponibilité des places pour candidater en tant que beta-testeur sur la Freebox Devialet :</p>
      <img src="https://img.shields.io/badge/Devialet-75%2F80%20occup%C3%A9es-DC2626?style=flat-square" alt="Bêta Devialet" />
    </td>
    <td width="50%" valign="top">
      <strong>Freebox Revolution</strong>
      <p>Disponibilité des places pour candidater en tant que beta-testeur sur la Freebox Revolution :</p>
      <img src="https://img.shields.io/badge/R%C3%A9volution-35%2F80%20occup%C3%A9es-brightgreen?style=flat-square" alt="Bêta Révolution" />
    </td>
  </tr>
</table>

Pour candidater en tant que bêta-testeur, il faut vous munir de votre n° d'abonné Freebox (commençant la plupart du temps par fbxXXX) que vous retrouvez sur votre espace client Freebox. Une fois que vous avez cette information, veuillez envoyer un mail en précisant êgalement la Freebox que vous avez et envoyez le tout à : application.redefin@proton.me.

<a id="prerequisites"></a>
### Prérequis

Vous devez disposer au moins de l'un des produits suivants pour bénéficier de cette application :

<p align="center"><a href="https://www.free.fr/freebox/"><img src="https://upload.wikimedia.org/wikipedia/commons/8/8a/Freebox_%28logo%29.svg" alt="Logo Freebox" width="118" /></a></p>

<table>
  <tr>
    <td width="50%" align="center" valign="top">
      <strong>Freebox Révolution</strong><br /><br />
      <a href="https://github.com/user-attachments/assets/691c2ed2-626e-4702-8277-9750ef365264">
        <img src="https://github.com/user-attachments/assets/691c2ed2-626e-4702-8277-9750ef365264" alt="Freebox Révolution" width="100%" />
      </a>
    </td>
    <td width="50%" align="center" valign="top">
      <strong>Freebox Delta-Devialet</strong><br /><br />
      <a href="https://github.com/user-attachments/assets/ee7d6788-fa02-4e52-aed8-ad6201c4454c">
        <img src="https://github.com/user-attachments/assets/ee7d6788-fa02-4e52-aed8-ad6201c4454c" alt="Freebox Delta Devialet" width="100%" />
      </a>
    </td>
  </tr>
</table>

<a id="installation"></a>
### Installation

Une fois votre mail envoyé à application.redefin@proton.me pour candidater en qualité de bêta-testeur, vous aurez une réponse vous confirmant la prise en compte de votre mail et la déclaration de votre n° d'abonné (identifiant Freebox) dans la liste des bêta-testeurs.

Vous pourrez alors vous rendre dans le Free Store sur votre Freebox Player afin de télécharger ReDeFin.

> [!CAUTION]
> **Utilisateurs Freebox Devialet**
>
> Pour télécharger ReDeFin depuis le Free Store, votre Freebox Devialet doit être rattachée à un abonnement Free permettant l'accès au Free Store.
>
> Si vous possédez une Freebox Devialet sans abonnement Free associé, merci de me contacter. Une méthode de test alternative pourrait vous permettre d'exécuter ReDeFin autrement.

---

<a id="usage"></a>
## Usage

Cette application vous permet de lire vos épisodes de séries et vos films de votre bibliothèque Jellyfin. Le support de la bibliothèque musicale et des chaines TV sont à l'étude.

_Pour plus d'exemples, Référez-vous à la [documentation officielle de Jellyfin](https://jellyfin.org/docs/)_

<a id="roadmap"></a>
## Roadmap

<table>
  <tr>
    <td width="34%" valign="top">
      <p><b>✓</b></p>
      <strong>Support de la bibliothèque Séries, Films et Collections</strong>
    </td>
    <td width="39%" valign="top">
      <p><b>✓</b></p>
      <strong>Lecteur vidéo compatible DirectPlay/Remux/DirectStream/Transcodage</strong>
    </td>
    <td width="27%" valign="top">
      <p><b>✓</b></p>
      <strong>Support multi-profil</strong>
    </td>
  </tr>
</table>

Voir [open issues](https://github.com/laborantine/ReDeFin/issues) pour un aperçu complet des nouvelles fonctionnalités (et des problèmes connus).

---

<a id="contributing"></a>
## Contributeurs

Les contributions font de la communauté open source un lieu exceptionnel pour apprendre, s'inspirer et créer. Toute contribution est **gratuitement appréciée**.

Si vous avez une suggestion pour améliorer ce projet, n'hésitez pas à forker le dépôt et à créer une pull request. Vous pouvez également ouvrir une issue avec l'étiquette « enhancement ».

Pensez à mettre une étoile au projet ! Merci encore ;)

### Top contributors:

<a href="https://github.com/laborantine/ReDeFin/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=laborantine/ReDeFin" alt="contrib.rocks image" />
</a>

---

<table>
<tr>
<td width="50%" valign="top">

<a id="license"></a>
<h2>Licence</h2>

<p>Distribuée sous la licence GPL 3.0. Regardez le fichier <code>LICENSE.txt</code> pour plus d'informations.</p>

</td>
<td width="50%" valign="top">

<a id="contact"></a>
<h2>Contact</h2>

<p>Laborantine - (<a href="https://github.com/laborantine/ReDeFin/issues">https://github.com/laborantine/ReDeFin/issues</a>) - application.redefin@proton.me</p>

<p>Lien officiel du projet : <a href="https://github.com/laborantine/ReDeFin">https://github.com/laborantine/ReDeFin</a></p>

</td>
</tr>
</table>

<a id="acknowledgments"></a>
## Remerciements

Un grand merci à :

- L'équipe de Free
- L'équipe des beta-testeurs
- OpenAI

<p align="center">
  <a href="https://ko-fi.com/B0B01NEJ0U"><img src="https://ko-fi.com/img/githubbutton_sm.svg" alt="ko-fi" /></a>
</p>

<p align="center"><a href="#readme-top">Retour en haut de page</a></p>

<!-- Les captures 1066x600 ont été préparées dans une discussion précédente ; elles doivent être ajoutées au dépôt. -->
<!-- Les logos correspondent aux marques et technologies réelles, sans signifier un partenariat officiel. -->
