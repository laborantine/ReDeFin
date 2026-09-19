// tst_fbxmodules.qml - Vérifie que les modules « fbx.* » utilisés par ReDeFin
// sont résolvables par le harnais de test headless.
//
// Deux origines distinctes :
//   - fbx.application / fbx.ui.base viennent de la bibliothèque officielle
//     Freebox libfbxqml (clonée par tools/fetch-libfbxqml.sh) ;
//   - fbx.system n'existe PAS dans libfbxqml (le firmware du Player le fournit
//     seul) : il est remplacé ici par le stub tests/qml/stubs/fbx/system.
//
// Ce test échoue donc si l'outillage est mal câblé (chemins d'import absents,
// clone libfbxqml manquant, stub cassé), ce qui rendrait muets tous les autres
// tests QML portant sur des composants du projet.
import QtQuick 2.15
import QtTest 1.2
import fbx.ui.base 1.0 as FbxBase
import fbx.system 1.0

TestCase {
    id: testCase
    name: "FbxModules"

    Component {
        id: clickableComponent
        FbxBase.Clickable {}
    }

    // fbx.ui.base : type réel de libfbxqml, instancié pour de bon.
    function test_clickableFromLibfbxqml() {
        var clickable = createTemporaryObject(clickableComponent, testCase);
        verify(clickable !== null, "fbx.ui.base 1.0 n'a pas pu être importé");
        compare(clickable.enabled, true);
        compare(clickable.pressed, false);
        // Taille implicite déclarée par clickable.qml : preuve que c'est bien
        // le composant de libfbxqml et non un homonyme.
        compare(clickable.implicitWidth, 135);
        compare(clickable.implicitHeight, 40);
    }

    // fbx.application : Application dérive de Window et se met en plein écran
    // dans son Component.onCompleted. On se contente donc de vérifier que le
    // composant se compile, sans l'instancier dans la session de test.
    function test_applicationComponentResolves() {
        // Compilation à la volée : le seul but est de résoudre l'import et de
        // prouver que Application est bien déclaré par le qmldir du clone.
        var holder = Qt.createQmlObject(
            'import QtQuick 2.15; import fbx.application 1.0; '
            + 'QtObject { property Component factory: Component { Application {} } }',
            testCase, "tst_fbxmodules_application");
        verify(holder !== null, "fbx.application 1.0 n'a pas pu être importé");
        compare(holder.factory.status, Component.Ready);
        holder.destroy();
    }

    // fbx.system : stub local, car le module n'existe que sur le Player.
    function test_deviceSingletonStub() {
        // Valeurs par défaut : Freebox Révolution.
        compare(Device.model, "fbx6hd");
        verify(String(Device.firmwareVersion).length > 0);
    }

    // Les tests doivent pouvoir simuler un autre Player (Delta/Devialet).
    function test_deviceSingletonIsOverridable() {
        var previousModel = Device.model;
        try {
            Device.model = "fbx7hd-delta";
            compare(Device.model, "fbx7hd-delta");
        } finally {
            // Un singleton est partagé par toute la session de test : on rend
            // toujours la valeur d'origine.
            Device.model = previousModel;
        }
        compare(Device.model, "fbx6hd");
    }
}
