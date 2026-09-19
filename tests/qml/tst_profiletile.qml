// tst_profiletile.qml - Câblage QML de la tuile de profil « Qui regarde ? ».
//
// Les tests Node (tests/js/pressgesture.test.js) couvrent la machine à états
// pure PressGesture. Ce qu'ils ne peuvent PAS couvrir, et qui est l'objet de
// ce fichier, c'est le câblage réel dans qml/pages/LoginPage.qml :
// Keys.onPressed / Keys.onReleased du delegate, les Timer preArm/commitTimer,
// la confirmation page._removeArmedUid et l'aboutissement des actions.
//
// Les trois correctifs couverts ici sont invisibles côté Node :
//   - suppression de la zone morte du tap court (un appui de ~300 ms doit
//     sélectionner, pas rester sans effet) ;
//   - verrou de touche OK jamais relâché (un appui refusé, ou le relâchement
//     « fantôme » qui suit un commitTimer, laissait la tuile sourde à OK) ;
//   - suppression d'un profil confirmée par un SECOND appui long.
//
// La vraie page est instanciée, sans réseau : serverUrl reste vide, donc
// _doLoadData() sort immédiatement (aucun XMLHttpRequest n'est émis), et
// settingsRef reste nul, donc _syncStoreSecurityPolicy() renvoie false et
// hydrateFromStore() n'est jamais appelée au chargement. Le modèle de profils
// est injecté après coup via localUsers + _recomputeModel(), exactement comme
// le ferait le store.
//
// Modules firmware : fbx.ui.base vient de libfbxqml et QtGraphicalEffects des
// stubs (voir tests/README.md). Les effets graphiques sont neutres : aucun
// test ci-dessous ne porte sur le rendu, uniquement sur la logique.
import QtQuick 2.15
import QtTest 1.2
import "../../qml/pages" as Pages

TestCase {
    id: testCase
    name: "ProfileTile"
    when: windowShown
    width: 1280
    height: 720

    // Durées d'appui. Elles gardent une marge par rapport aux seuils de la
    // tuile (_preArmMs 1000 + _commitMs 1000, _fallbackLongMs 2000) pour que
    // le test ne dépende pas de la précision des timers.
    readonly property int tapMs: 50            // tap franc
    readonly property int deadZoneMs: 350      // ancienne « zone morte » (~300 ms)
    readonly property int longPressMs: 2400    // au-delà de preArm + commit
    // Temps laissé aux Qt.callLater et aux Timer déclenchés par une action.
    readonly property int settleMs: 80

    readonly property string uid: "u-alice"

    Component {
        id: loginComponent
        // serverUrl vide : aucune requête réseau ne peut partir.
        Pages.LoginPage { serverUrl: "" }
    }

    // Crée une LoginPage prête à l'emploi, avec un seul profil sans token et
    // le focus posé sur sa tuile.
    function newLoginPage() {
        var page = createTemporaryObject(loginComponent, testCase);
        verify(page !== null, "LoginPage.qml n'a pas pu être instanciée");

        // Laisse Component.onCompleted et le debounce de loadData() (120 ms)
        // se terminer avant d'injecter le modèle, sinon _recomputeModel() du
        // debounce passerait après nous.
        wait(250);
        compare(page.loading, false, "loadData() aurait dû sortir sans serveur");

        // Profil local sans token : une sélection réussie appelle donc
        // openLoginForUser(), ce qui ouvre le volet de connexion.
        page.localUsers = [{ Id: testCase.uid, Name: "Alice" }];
        page._recomputeModel();
        compare(page.usersModel.length, 1);

        page.forceActiveFocus();
        page.ensureProfileCarouselFocus();
        wait(100);

        verify(!page.overlayOpen, "aucun volet ne doit être ouvert au départ");
        compare(page._removeArmedUid, "");
        return page;
    }

    // Appui OK maintenu `holdMs` millisecondes sur la tuile qui a le focus.
    function pressOk(holdMs) {
        keyPress(Qt.Key_Return);
        wait(holdMs);
        keyRelease(Qt.Key_Return);
        wait(testCase.settleMs);
    }

    // Observable de la sélection : sans token, selectThis() appelle
    // openLoginForUser(), qui active le volet de connexion. page.overlayOpen
    // en est le reflet public (loginOverlay lui-même est interne à la page).
    function verifySelected(page, message) {
        verify(page.overlayOpen, message);
    }

    // --- 1. Appui de ~300 ms : l'ancienne zone morte doit avoir disparu ---
    function test_mediumPressSelectsProfile() {
        var page = newLoginPage();
        pressOk(testCase.deadZoneMs);
        verifySelected(page, "un appui de 350 ms doit sélectionner le profil");
        compare(page._removeArmedUid, "", "un appui moyen ne doit rien armer");
    }

    // --- 2. Tap court : sélection, comme avant ---
    function test_shortTapSelectsProfile() {
        var page = newLoginPage();
        pressOk(testCase.tapMs);
        verifySelected(page, "un tap court doit sélectionner le profil");
    }

    // --- 3. Appui refusé puis appui normal : le verrou ne reste pas posé ---
    function test_refusedPressDoesNotLockOkKey() {
        var page = newLoginPage();

        // Le bouclier d'entrée global prend normalement le focus quand ce
        // drapeau est levé. On le rend à la tuile pour rejouer le cas qui
        // faisait la régression : la touche OK atteint la tuile alors que
        // l'appui doit être refusé par _canBeginPress().
        page._okSwallowUntilRelease = true;
        page.ensureProfileCarouselFocus();
        wait(testCase.settleMs);

        pressOk(testCase.tapMs);
        verify(!page.overlayOpen, "un appui refusé ne doit rien sélectionner");

        // Fin du refus : la tuile doit redevenir réceptive immédiatement.
        page._okSwallowUntilRelease = false;
        page.ensureProfileCarouselFocus();
        wait(testCase.settleMs);

        pressOk(testCase.tapMs);
        verifySelected(page, "l'appui suivant un refus doit sélectionner (verrou levé)");
    }

    // --- 4. Appui long : le premier arme, le second supprime ---
    function test_longPressArmsThenSecondLongPressRemoves() {
        var page = newLoginPage();

        pressOk(testCase.longPressMs);
        compare(page._removeArmedUid, testCase.uid,
                "un premier appui long doit armer la confirmation");
        compare(page.usersModel.length, 1,
                "un seul appui long ne doit JAMAIS supprimer le profil");
        verify(!page.overlayOpen, "l'armement ne doit pas ouvrir de volet");

        // Ce second appui long est aussi le cas du relâchement « fantôme » :
        // commitTimer a déjà réinitialisé l'appui avant le relâchement. C'est
        // ce chemin qui laissait autrefois le verrou de touche posé.
        pressOk(testCase.longPressMs);
        // logoutAndRemoveById() reconstruit le modèle via des Qt.callLater.
        wait(300);
        compare(page.usersModel.length, 0, "le second appui long doit supprimer le profil");
        compare(page._removeArmedUid, "", "la confirmation doit être désarmée après suppression");
    }

    // --- 5. Armement puis tap court : désarmement et sélection normale ---
    function test_shortTapDisarmsPendingRemoval() {
        var page = newLoginPage();

        pressOk(testCase.longPressMs);
        compare(page._removeArmedUid, testCase.uid);

        pressOk(testCase.tapMs);
        compare(page._removeArmedUid, "", "un tap court doit désarmer la confirmation");
        compare(page.usersModel.length, 1, "un tap court ne doit rien supprimer");
        verifySelected(page, "un tap court pendant l'armement doit sélectionner le profil");
    }
}
