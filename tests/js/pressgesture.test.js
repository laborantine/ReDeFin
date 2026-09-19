'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { loadQmlJs } = require('./qmljs');

const PressGesture = loadQmlJs('qml/js/PressGesture.js');

// Réglages identiques à ceux des appelants QML (tuile de profil LoginPage,
// ligne de serveur mémorisé ServerOverlay).
const CFG = { commitMs: 1000, fallbackLongMs: 2000 };

function decide(extra) {
    return PressGesture.decideRelease(Object.assign({}, CFG, extra));
}

test('decideRelease : tout relâchement sous le seuil de suppression sélectionne', () => {
    // Tap franc.
    assert.equal(decide({ dur: 50, armed: false }), 'select');
    assert.equal(decide({ dur: 0, armed: false }), 'select');

    // Ancienne « zone morte » silencieuse (201..1999 ms) : c'était le bug.
    assert.equal(decide({ dur: 201, armed: false }), 'select');
    assert.equal(decide({ dur: 300, armed: false }), 'select');
    assert.equal(decide({ dur: 900, armed: false }), 'select');
    assert.equal(decide({ dur: 1500, armed: false }), 'select');
    assert.equal(decide({ dur: 1999, armed: false }), 'select');
});

test('decideRelease : appui long amorcé puis abandonné sélectionne', () => {
    // L'anneau a démarré (armed) mais l'utilisateur relâche avant la fin.
    assert.equal(decide({ dur: 1300, armed: true, armedDur: 300 }), 'select');
    assert.equal(decide({ dur: 1999, armed: true, armedDur: 999 }), 'select');
});

test('decideRelease : appui long confirmé supprime', () => {
    // Anneau arrivé au bout.
    assert.equal(decide({ dur: 1000, armed: true, armedDur: 1000 }), 'remove');
    assert.equal(decide({ dur: 1500, armed: true, armedDur: 1400 }), 'remove');

    // Garde-fou : appui total très long, même sans amorçage (timer non tiré).
    assert.equal(decide({ dur: 2000, armed: false }), 'remove');
    assert.equal(decide({ dur: 5000, armed: false }), 'remove');
    assert.equal(decide({ dur: 3000, armed: true, armedDur: 10 }), 'remove');
});

test('decideRelease : bornes exactes', () => {
    // commitMs : >= supprime, juste en dessous sélectionne.
    assert.equal(decide({ dur: 1200, armed: true, armedDur: 999 }), 'select');
    assert.equal(decide({ dur: 1200, armed: true, armedDur: 1000 }), 'remove');

    // fallbackLongMs : >= supprime, juste en dessous sélectionne.
    assert.equal(decide({ dur: 1999, armed: false }), 'select');
    assert.equal(decide({ dur: 2000, armed: false }), 'remove');

    // armedDur n'est pris en compte que si armed vaut vrai.
    assert.equal(decide({ dur: 500, armed: false, armedDur: 9999 }), 'select');
});

test('decideRelease : aucun appui en cours => "none"', () => {
    assert.equal(decide({ active: false, dur: 50 }), 'none');
    assert.equal(decide({ active: false, dur: 9999, armed: true, armedDur: 9999 }), 'none');

    // active absent ou vrai => l'appui est considéré en cours.
    assert.equal(decide({ active: true, dur: 50 }), 'select');
    assert.equal(PressGesture.decideRelease({ dur: 50 }), 'select');
});

test('decideRelease : entrées invalides retombent sur des valeurs sûres', () => {
    assert.equal(PressGesture.decideRelease(), 'select');
    assert.equal(PressGesture.decideRelease(null), 'select');

    // dur non numérique => 0 ms => sélection (jamais de suppression surprise).
    assert.equal(decide({ dur: undefined, armed: false }), 'select');
    assert.equal(decide({ dur: NaN, armed: false }), 'select');
    assert.equal(decide({ dur: 'abc', armed: false }), 'select');

    // Seuils absents ou aberrants : repli sur 1000 / 2000 ms.
    assert.equal(PressGesture.decideRelease({ dur: 2500 }), 'remove');
    assert.equal(PressGesture.decideRelease({ dur: 1500 }), 'select');
    assert.equal(
        PressGesture.decideRelease({ dur: 1200, armed: true, armedDur: 1100, commitMs: 0 }),
        'remove'
    );
});

/* ---------------------------------------------------------------------- */
/* Machine à états d'appui (verrou de touche)                             */
/* ---------------------------------------------------------------------- */

test('createMachine : instances indépendantes, état initial propre', () => {
    const a = PressGesture.createMachine();
    const b = PressGesture.createMachine();

    assert.equal(a.keyHeld, false);
    assert.equal(a.pressActive, false);
    assert.equal(a.armed, false);

    a.keyDown(0, true);
    assert.equal(a.keyHeld, true);
    // Malgré le .pragma library, rien n'est partagé entre deux machines.
    assert.equal(b.keyHeld, false);
    assert.equal(b.pressActive, false);
});

test('createMachine : appui nominal => sélection', () => {
    const m = PressGesture.createMachine();

    assert.equal(m.keyDown(1000, true), 'begin');
    assert.equal(m.pressActive, true);
    assert.equal(m.keyUp(1300, CFG), 'select');
    assert.equal(m.keyHeld, false);
    assert.equal(m.pressActive, false);
});

test('createMachine : un appui refusé ne verrouille pas la touche', () => {
    const m = PressGesture.createMachine();

    // Appui refusé (latch post-logout, bouclier OK, uid manquant...).
    assert.equal(m.keyDown(1000, false), 'ignore');
    assert.equal(m.keyHeld, false, 'le verrou ne doit pas être posé');
    assert.equal(m.pressActive, false);

    // Relâchement correspondant : aucune action, et rien ne reste bloqué.
    assert.equal(m.keyUp(1100, CFG), 'none');
    assert.equal(m.keyHeld, false);

    // L'appui suivant, lui accepté, doit sélectionner normalement : c'était
    // le bug (la tuile ignorait définitivement OK après un appui refusé).
    assert.equal(m.keyDown(2000, true), 'begin');
    assert.equal(m.keyUp(2300, CFG), 'select');
});

test('createMachine : appui refusé sans relâchement, puis appui accepté', () => {
    const m = PressGesture.createMachine();

    // Cas le plus vicieux : le relâchement du premier appui n'arrive jamais
    // (la tuile a perdu le focus, l'évènement a été avalé par le bouclier).
    assert.equal(m.keyDown(1000, false), 'ignore');
    assert.equal(m.keyDown(2000, true), 'begin');
    assert.equal(m.keyUp(2300, CFG), 'select');
});

test('createMachine : relâchement fantôme sans appui ne bloque rien', () => {
    const m = PressGesture.createMachine();

    assert.equal(m.keyUp(500, CFG), 'none');
    assert.equal(m.keyHeld, false);
    assert.equal(m.pressActive, false);

    assert.equal(m.keyDown(1000, true), 'begin');
    assert.equal(m.keyUp(1400, CFG), 'select');
});

test('createMachine : autorepeat / keyDown en double ignorés', () => {
    const m = PressGesture.createMachine();

    assert.equal(m.keyDown(1000, true), 'begin');
    assert.equal(m.keyDown(1100, true), 'ignore');
    assert.equal(m.keyDown(1200, true), 'ignore');
    // La durée reste mesurée depuis le PREMIER appui.
    assert.equal(m.downAtMs, 1000);
    assert.equal(m.keyUp(1500, CFG), 'select');
});

test('createMachine : armedNow() et appui long confirmé', () => {
    const m = PressGesture.createMachine();

    m.keyDown(1000, true);
    assert.equal(m.armedNow(2000), true);
    assert.equal(m.armed, true);
    assert.equal(m.armedAtMs, 2000);

    // Relâchement avant la fin de l'anneau : sélection.
    assert.equal(m.keyUp(2500, CFG), 'select');

    // Anneau mené à son terme : suppression.
    const m2 = PressGesture.createMachine();
    m2.keyDown(0, true);
    m2.armedNow(1000);
    assert.equal(m2.keyUp(2000, CFG), 'remove');
});

test('createMachine : armedNow() sans appui en cours est sans effet', () => {
    const m = PressGesture.createMachine();

    // Timer d'amorçage arrivé en retard, après un reset (suppression déjà
    // exécutée, perte de focus...) : il ne doit pas réarmer la machine.
    assert.equal(m.armedNow(1000), false);
    assert.equal(m.armed, false);

    m.keyDown(1000, true);
    m.reset();
    assert.equal(m.armedNow(2000), false);
    assert.equal(m.armed, false);
});

test('createMachine : reset() abandonne l’appui mais garde le verrou', () => {
    const m = PressGesture.createMachine();

    m.keyDown(1000, true);
    m.armedNow(2000);
    // Cas du commitTimer : la suppression part alors que la touche est encore
    // enfoncée. L'appui est abandonné, mais le verrou reste posé jusqu'au
    // relâchement réel, pour ne pas redémarrer un appui sur l'autorepeat.
    m.reset();
    assert.equal(m.pressActive, false);
    assert.equal(m.armed, false);
    assert.equal(m.keyHeld, true);

    // Le relâchement ne déclenche plus rien et lève le verrou.
    assert.equal(m.keyUp(3500, CFG), 'none');
    assert.equal(m.keyHeld, false);

    // Et l'appui suivant repart normalement.
    assert.equal(m.keyDown(4000, true), 'begin');
    assert.equal(m.keyUp(4200, CFG), 'select');
});

/* ---------------------------------------------------------------------- */
/* Confirmation de suppression (« Appuyez encore sur OK »)                */
/* ---------------------------------------------------------------------- */

// Les objets rendus viennent du contexte `vm` du module : leur prototype
// n'est pas celui de Node, donc deepStrictEqual() échouerait. On compare
// donc champ à champ.
function assertRemoveState(actual, armedUid, execute, message) {
    assert.equal(actual.armedUid, armedUid, message);
    assert.equal(actual.execute, execute, message);
}

test('nextRemoveState : le premier appui long arme, le second supprime', () => {
    const first = PressGesture.nextRemoveState('', 'u1', 'remove');
    assertRemoveState(first, 'u1', false);

    const second = PressGesture.nextRemoveState(first.armedUid, 'u1', 'remove');
    assertRemoveState(second, '', true);

    // Après exécution, plus rien n'est armé : un nouvel appui long réarme.
    assertRemoveState(PressGesture.nextRemoveState(second.armedUid, 'u1', 'remove'), 'u1', false);
});

test('nextRemoveState : un appui long sur une autre tuile réarme sans supprimer', () => {
    assertRemoveState(PressGesture.nextRemoveState('u1', 'u2', 'remove'), 'u2', false);
});

test('nextRemoveState : un tap pendant l’armement désarme sans supprimer', () => {
    // La sélection elle-même reste à la charge de l'appelant.
    assertRemoveState(PressGesture.nextRemoveState('u1', 'u1', 'select'), '', false);
    assertRemoveState(PressGesture.nextRemoveState('u1', 'u2', 'select'), '', false);
    assertRemoveState(PressGesture.nextRemoveState('', 'u1', 'select'), '', false);
});

test('nextRemoveState : "none" et identifiants manquants', () => {
    // Relâchement fantôme : rien ne bouge, l'armement en cours est conservé.
    assertRemoveState(PressGesture.nextRemoveState('u1', 'u1', 'none'), 'u1', false);
    assertRemoveState(PressGesture.nextRemoveState('', 'u1', 'none'), '', false);

    // Sans identifiant visé, aucune suppression possible.
    assertRemoveState(PressGesture.nextRemoveState('u1', '', 'remove'), '', false);
    assertRemoveState(PressGesture.nextRemoveState(undefined, undefined, 'remove'), '', false);

    // Un armement vide ne peut jamais déclencher d'exécution.
    assertRemoveState(PressGesture.nextRemoveState(null, 'u1', 'remove'), 'u1', false);
});

/* ---------------------------------------------------------------------- */
/* Cas propres à ServerOverlay (mêmes primitives partagées)               */
/* ---------------------------------------------------------------------- */

test('ServerOverlay : le seuil de tap court de 220 ms ne bloque plus le choix', () => {
    // ServerOverlay utilisait _shortTapMs = 220 ms et ignorait tout
    // relâchement entre 221 et 1999 ms. Les seuils de suppression sont
    // identiques à ceux de LoginPage (commitMs 1000, fallbackLongMs 2000).
    assert.equal(decide({ dur: 221, armed: false }), 'select');
    assert.equal(decide({ dur: 500, armed: false }), 'select');
    assert.equal(decide({ dur: 1800, armed: false }), 'select');
    assert.equal(decide({ dur: 1700, armed: true, armedDur: 700 }), 'select');

    // Et la suppression reste possible exactement aux mêmes seuils.
    assert.equal(decide({ dur: 2000, armed: false }), 'remove');
    assert.equal(decide({ dur: 1500, armed: true, armedDur: 1000 }), 'remove');
});

test('ServerOverlay : confirmation de suppression indexée par URL', () => {
    // Ici l'identité d'une ligne est son URL normalisée, pas un uid : la
    // fonction est agnostique du type d'identifiant.
    const first = PressGesture.nextRemoveState('', 'http://nas.local:8096', 'remove');
    assertRemoveState(first, 'http://nas.local:8096', false);

    // Un appui long sur une AUTRE ligne réarme sur celle-ci.
    assertRemoveState(
        PressGesture.nextRemoveState(first.armedUid, 'http://autre.local:8096', 'remove'),
        'http://autre.local:8096',
        false
    );

    // Second appui long sur la même ligne : suppression.
    assertRemoveState(
        PressGesture.nextRemoveState(first.armedUid, 'http://nas.local:8096', 'remove'),
        '',
        true
    );

    // Un choix de serveur pendant l'armement annule la confirmation.
    assertRemoveState(
        PressGesture.nextRemoveState(first.armedUid, 'http://nas.local:8096', 'select'),
        '',
        false
    );

    // Ligne sans URL exploitable : rien n'est armé ni supprimé.
    assertRemoveState(PressGesture.nextRemoveState('', '', 'remove'), '', false);
});
