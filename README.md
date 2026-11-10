<a id="readme-top"></a>

<div align="center">
  <a href="https://github.com/user-attachments/assets/c14346df-2e99-482b-9c6d-d064583890bd">
    <img src="https://github.com/user-attachments/assets/c14346df-2e99-482b-9c6d-d064583890bd" alt="Logo officiel ReDeFin" width="136" />
  </a>

  <h1>ReDeFin</h1>
  <h3>Un client Jellyfin non officiel pour lire votre bibliothèque sur Freebox</h3>

  <p>ReDeFin est un client non officiel Jellyfin pensé spécialement pour les Freebox Player (Révolution / Devialet).</p>
  <p>Son objectif : Profiter de votre bibliothèque comme sur une grande plateforme de streaming avec votre serveur, vos fichiers, votre Freebox.</p>

  <p>
    <a href="https://github.com/laborantine/ReDeFin"><strong>Voir la documentation</strong></a>
    &nbsp;&nbsp;·&nbsp;&nbsp;
    <a href="https://github.com/laborantine/ReDeFin/issues/new?labels=bug&amp;template=bug-report---.md">Rapporter un bug</a>
    &nbsp;&nbsp;·&nbsp;&nbsp;
    <a href="https://github.com/laborantine/ReDeFin/issues/new?labels=enhancement&amp;template=feature-request---.md">Suggérer une nouvelle fonctionnalité</a>
  </p>

  <p>
    <a href="https://github.com/laborantine/ReDeFin/stargazers"><img alt="Étoiles" src="https://img.shields.io/github/stars/laborantine/ReDeFin?style=flat-square&amp;label=Stars&amp;color=6C5CE7&amp;logo=github&amp;logoColor=white" /></a>
    <a href="https://github.com/laborantine/ReDeFin/network/members"><img alt="Forks" src="https://img.shields.io/github/forks/laborantine/ReDeFin?style=flat-square&amp;label=Forks&amp;color=6C5CE7" /></a>
    <a href="https://github.com/laborantine/ReDeFin/issues"><img alt="Issues" src="https://img.shields.io/github/issues/laborantine/ReDeFin?style=flat-square&amp;label=Issues&amp;color=6C5CE7" /></a>
    <a href="https://github.com/laborantine/ReDeFin/graphs/contributors"><img alt="Contributeurs" src="https://img.shields.io/github/contributors/laborantine/ReDeFin?style=flat-square&amp;label=Contributors&amp;color=6C5CE7" /></a>
    <a href="https://github.com/laborantine/ReDeFin/blob/main/LICENSE"><img alt="Licence GPL" src="https://img.shields.io/github/license/laborantine/ReDeFin?style=flat-square&amp;label=License&amp;color=6C5CE7" /></a>
  </p>
  <p>
    <a href="https://www.qt.io/"><img alt="QtQuick 2.15, framework Qt" src="https://img.shields.io/badge/QML-QtQuick%202.15-191F37?style=flat-square&amp;logo=qt&amp;logoColor=41CD52" /></a>
    <a href="https://developer.mozilla.org/fr/docs/Web/JavaScript"><img alt="JavaScript" src="https://img.shields.io/badge/JavaScript-191F37?style=flat-square&amp;logo=javascript&amp;logoColor=F7DF1E" /></a>
    <a href="https://jellyfin.org/"><img alt="Jellyfin, client non officiel" src="https://img.shields.io/badge/Jellyfin-Client%20non%20officiel-191F37?style=flat-square&amp;logo=jellyfin&amp;logoColor=A98CEE" /></a>
    <a href="#prerequisites"><img alt="Freebox Révolution et Devialet" src="https://img.shields.io/badge/Freebox-R%C3%A9volution%20%7C%20Devialet-191F37?style=flat-square" /></a>
  </p>
</div>

---

<!-- Navigation compacte : les intitulés reprennent ceux du README d'origine. -->
<div align="center">
  <a href="#captures">Captures</a> &nbsp;·&nbsp;
  <a href="#about-this-project">A propos de ce projet</a> &nbsp;·&nbsp;
  <a href="#getting-started">Introduction</a> &nbsp;·&nbsp;
  <a href="#usage">Usage</a> &nbsp;·&nbsp;
  <a href="#roadmap">Roadmap</a> &nbsp;·&nbsp;
  <a href="#contributing">Contributeurs</a>
</div>

<details>
<summary><strong>Table des matières</strong></summary>

- [Captures d’écran](#captures)
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

<a id="captures"></a>
## Captures d’écran

<!-- Captures ReDeFin préparées le 15 octobre 2026 (1066 × 600).
     Aucun mockup ni visuel conceptuel n’est utilisé dans cette section. -->

<div align="center">
  <a href="docs/screenshots/ReDeFin_02_Accueil_1066x600.jpg">
    <img src="docs/screenshots/ReDeFin_02_Accueil_1066x600.jpg" alt="Interface d’accueil ReDeFin sur Freebox" width="100%" />
  </a>
  <p><sub><strong>Accueil</strong></sub></p>
</div>

<table>
  <tr>
    <td width="50%" align="center" valign="top">
      <a href="docs/screenshots/ReDeFin_01_Profils_1066x600.jpg">
        <img src="docs/screenshots/ReDeFin_01_Profils_1066x600.jpg" alt="Sélection des profils ReDeFin" width="100%" />
      </a>
      <br />
      <sub><strong>Profils</strong></sub>
    </td>
    <td width="50%" align="center" valign="top">
      <a href="docs/screenshots/ReDeFin_03_Collection_1066x600.jpg">
        <img src="docs/screenshots/ReDeFin_03_Collection_1066x600.jpg" alt="Interface de collection Éclipse dans ReDeFin" width="100%" />
      </a>
      <br />
      <sub><strong>Collection</strong></sub>
    </td>
  </tr>
</table>

<p align="right"><a href="#readme-top">Retour en haut de page</a></p>

---

<a id="about-this-project"></a>
## A propos de ce projet

ReDeFin est un client Jellyfin NON OFFICIEL codé en QML et JavaScript, compatible Freebox Revolution et Freebox Delta (Devialet).

L'objectif souhaité est de se rapprocher visuellement et fonctionnellement de ce que le client officiel Android TV est capable de faire.


<a id="built-with"></a>
<div align="center">
  <a href="https://chatgpt.com/fr-FR"><img src="https://img.shields.io/badge/ChatGPT-OpenAI-263238?style=for-the-badge&amp;logo=openai&amp;logoColor=white" alt="ChatGPT, OpenAI" /></a>
</div>

<details>
<summary><strong>Fabriqué avec</strong></summary>

### Fabriqué avec

* [![chatgpt.com][chatgpt.com]][chatgpt-url]

Ce projet a été intégralement fabriqué à partir de ChatGPT depuis 2024. Il a été fabriqué à partir des modèles de langages suivants :

**Travaux préliminaires (2024 - mars 2025) :**

- GPT-3.5
- GPT-4
- GPT-4o

**Travaux principaux (avril 2025 - maintenant) :**

- GPT-4.5
- GPT-5
- GPT-5.1
- GPT-5.2
- GPT-5.4
- GPT-5.5
- GPT-5.6 Sol
- GPT 6.1 Sol

</details>

<p align="right"><a href="#readme-top">Retour en haut de page</a></p>

---

<a id="getting-started"></a>
## Introduction

<div align="center">
  <img src="https://img.shields.io/badge/Places-110%20occup%C3%A9es%20sur%20160%20%E2%80%94%2050%20restantes-orange?style=for-the-badge" alt="Places bêta" />
</div>

Le projet est actuellement en phase bêta fermé.

<table>
  <tr>
    <td width="50%" align="center" valign="top">
      <p>Disponibilité des places pour candidater en tant que beta-testeur sur la Freebox Devialet :</p>
      <img src="https://img.shields.io/badge/Devialet-75%2F80%20occup%C3%A9es-DC2626?style=for-the-badge" alt="Bêta Devialet" />
    </td>
    <td width="50%" align="center" valign="top">
      <p>Disponibilité des places pour candidater en tant que beta-testeur sur la Freebox Revolution :</p>
      <img src="https://img.shields.io/badge/R%C3%A9volution-35%2F80%20occup%C3%A9es-brightgreen?style=for-the-badge" alt="Bêta Révolution" />
    </td>
  </tr>
</table>

Pour candidater en tant que bêta-testeur, il faut vous munir de votre n° d'abonné Freebox (commençant la plupart du temps par fbxXXX) que vous retrouvez sur votre espace client Freebox. Une fois que vous avez cette information, veuillez envoyer un mail en précisant êgalement la Freebox que vous avez et envoyez le tout à : application.redefin@proton.me.

<a id="prerequisites"></a>
### Prérequis

Vous devez disposer au moins de l'un des produits suivants pour bénéficier de cette application :

<div align="center">
  <a href="https://www.free.fr/freebox/" title="Freebox, marque de Free">
    <img src="https://upload.wikimedia.org/wikipedia/commons/8/8a/Freebox_%28logo%29.svg" alt="Logo Freebox" width="132" />
  </a>
</div>

<table>
  <tr>
    <td width="50%" align="center" valign="top">
      <strong>Freebox Révolution</strong><br /><br />
      <a href="https://github.com/user-attachments/assets/691c2ed2-626e-4702-8277-9750ef365264">
        <img src="https://github.com/user-attachments/assets/691c2ed2-626e-4702-8277-9750ef365264" alt="Freebox Révolution" width="420" />
      </a>
    </td>
    <td width="50%" align="center" valign="top">
      <strong>Freebox Delta-Devialet</strong><br /><br />
      <a href="https://github.com/user-attachments/assets/ee7d6788-fa02-4e52-aed8-ad6201c4454c">
        <img src="https://github.com/user-attachments/assets/ee7d6788-fa02-4e52-aed8-ad6201c4454c" alt="Freebox Delta Devialet" width="420" />
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

<p align="right"><a href="#readme-top">Retour en haut de page</a></p>

---

<a id="usage"></a>
## Usage

Cette application vous permet de lire vos épisodes de séries et vos films de votre bibliothèque Jellyfin. Le support de la bibliothèque musicale et des chaines TV sont à l'étude.

_Pour plus d'exemples, Référez-vous à la [documentation officielle de Jellyfin](https://jellyfin.org/docs/)_

<p align="right"><a href="#readme-top">Retour en haut de page</a></p>

---

<a id="roadmap"></a>
## Roadmap

<table>
  <tr>
    <td align="center" width="34%" valign="top">
      <h3>✓</h3>
      <strong>Support de la bibliothèque Séries, Films et Collections</strong>
    </td>
    <td align="center" width="40%" valign="top">
      <h3>✓</h3>
      <strong>Lecteur vidéo compatible DirectPlay/Remux/DirectStream/Transcodage</strong>
    </td>
    <td align="center" width="26%" valign="top">
      <h3>✓</h3>
      <strong>Support multi-profil</strong>
    </td>
  </tr>
</table>

Voir [open issues](https://github.com/laborantine/ReDeFin/issues) pour un aperçu complet des nouvelles fonctionnalités (et des problèmes connus).

<p align="right"><a href="#readme-top">Retour en haut de page</a></p>

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

<p align="right"><a href="#readme-top">Retour en haut de page</a></p>

---

<a id="license"></a>
## Licence

Distribuée sous la licence GPL 3.0. Regardez le fichier `LICENSE.txt` pour plus d'informations.

<a id="contact"></a>
## Contact

Laborantine - (https://github.com/laborantine/ReDeFin/issues) - application.redefin@proton.me

Lien officiel du projet : [https://github.com/laborantine/ReDeFin](https://github.com/laborantine/ReDeFin)

<p align="right"><a href="#readme-top">Retour en haut de page</a></p>

---

<a id="acknowledgments"></a>
## Remerciements

Un grand merci à :

- L'équipe de Free
- L'équipe des beta-testeurs
- OpenAI

<p align="right"><a href="#readme-top">Retour en haut de page</a></p>

<div align="center">
  <a href="https://ko-fi.com/B0B01NEJ0U"><img src="https://ko-fi.com/img/githubbutton_sm.svg" alt="ko-fi" /></a>
</div>

<!-- Références conservées du dépôt d'origine. -->
[contributors-shield]: https://img.shields.io/github/contributors/laborantine/ReDeFin.svg?style=for-the-badge
[contributors-url]: https://github.com/laborantine/ReDeFin/network/dependencies
[forks-shield]: https://img.shields.io/github/forks/laborantine/ReDeFin.svg?style=for-the-badge
[forks-url]: https://github.com/laborantine/ReDeFin/network/members
[stars-shield]: https://img.shields.io/github/stars/laborantine/ReDeFin.svg?style=for-the-badge
[stars-url]: https://github.com/laborantine/ReDeFin/stargazers
[issues-shield]: https://img.shields.io/github/issues/laborantine/ReDeFin.svg?style=for-the-badge
[issues-url]: https://github.com/laborantine/ReDeFin/issues
[license-shield]: https://img.shields.io/github/license/laborantine/ReDeFin.svg?style=for-the-badge
[license-url]: https://github.com/laborantine/ReDeFin/blob/main/LICENSE
[product-screenshot]: images/screenshot.png
[chatgpt.com]: https://img.shields.io/badge/chatGPT-74aa9c?style=for-the-badge&logo=openai&logoColor=white
[chatgpt-url]: https://chatgpt.com/fr-FR

