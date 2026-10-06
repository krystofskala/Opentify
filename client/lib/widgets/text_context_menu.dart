import 'package:flutter/material.dart';

/// Kontextové menu textového pole: na iOS nativní systémové (Vložit,
/// Skenovat text...). Flutterovo vlastní menu nabízí "Vložit" jen podle
/// odhadu stavu schránky, který po návratu z jiné appky často nesedí --
/// místo Vložit se pak ukázalo jen "Scan Text". Jinde výchozí menu.
Widget adaptiveTextContextMenu(BuildContext context, EditableTextState state) {
  if (SystemContextMenu.isSupportedByField(state)) {
    return SystemContextMenu.editableText(editableTextState: state);
  }
  return AdaptiveTextSelectionToolbar.editableText(editableTextState: state);
}
