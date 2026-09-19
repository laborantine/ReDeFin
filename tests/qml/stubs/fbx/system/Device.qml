// Device.qml - Stub du singleton « fbx.system.Device » du firmware Freebox.
//
// Seules les propriétés réellement lues par ReDeFin sont exposées :
//   - main.qml                : Device.model (+ Device passé à
//                               ClientId.initFromQmlDevice())
//   - qml/pages/ShellPage.qml : Device.model, Device.firmwareVersion
// Aucune méthode de Device n'est appelée par l'application.
//
// Les valeurs par défaut décrivent une Freebox Révolution (Player v6) :
// ClientId.freeboxPlayerModeFromModel("fbx6hd") rend « revolution ».
// Elles sont volontairement de simples `property` (et non `readonly`) pour
// qu'un test puisse les surcharger, par exemple :
//     Device.model = "fbx7hd-delta"   // Player Devialet
pragma Singleton
import QtQuick 2.15

QtObject {
    // Code modèle du Player, tel que remonté par le firmware.
    //   fbx6hd       : Freebox Révolution
    //   fbx7hd-delta : Freebox Delta / Player Devialet
    property string model: "fbx6hd"

    // Version du firmware du Player.
    property string firmwareVersion: "1.3.34"

    // Nom d'affichage du Player. Non utilisé par ReDeFin aujourd'hui, mais
    // ClientId.initFromQmlDevice() sait le lire en repli de `model`.
    property string name: "Freebox Player"
}
