// tst_smoke.qml - Test de fumée pour le harnais Qt Quick Test.
//
// Objectif : prouver que run_qml_tests.py sait exécuter un test QtTest
// headless sur un composant réel du projet. On charge
// qml/components/CircleDotsLoader.qml, qui n'a aucune dépendance aux
// modules fbx.* du firmware (uniquement QtQuick 2.15), et on vérifie ses
// valeurs par défaut ainsi qu'une réaction simple à un changement de
// propriété.
import QtQuick 2.15
import QtTest 1.2
import "../../qml/components" as Components

TestCase {
    id: testCase
    name: "Smoke"

    Component {
        id: loaderComponent
        Components.CircleDotsLoader {}
    }

    function test_defaultProperties() {
        var dots = createTemporaryObject(loaderComponent, testCase);
        verify(dots !== null);
        compare(dots.dotCount, 12);
        compare(dots.dotSize, 8);
        compare(dots.active, true);
        compare(dots.litCount, 0);
    }

    function test_dotCountChangeResetsLitCount() {
        var dots = createTemporaryObject(loaderComponent, testCase, { litCount: 5 });
        compare(dots.litCount, 5);

        dots.dotCount = 20;

        compare(dots.dotCount, 20);
        compare(dots.litCount, 0);
    }
}
