import 'package:flutter/material.dart';

import 'glass/glass_back_button.dart';

/// Sdílený vzhled AppBaru -- nahrazuje 5 různých ad hoc přístupů napříč
/// obrazovkami (Home/Profil holý `AppBar`, Library `AppBar`+`TabBar`, Search
/// s `TextField` natvrdo v `title`, Release bez AppBaru vůbec na úspěšné
/// cestě, Artist s vlastním titulkem uvnitř `FlexibleSpaceBar`). Styl
/// (tučný, mírně záporný `letterSpacing`) přichází z `AppBarTheme` v
/// `theme/app_theme.dart` -- tenhle widget jen sjednocuje *strukturu*
/// (transparentní pozadí, `bottom` slot), ne barvy/písmo.
class SectionAppBar extends StatelessWidget implements PreferredSizeWidget {
  const SectionAppBar(this.title, {super.key, this.actions, this.bottom});

  final String title;
  final List<Widget>? actions;
  final PreferredSizeWidget? bottom;

  @override
  Widget build(BuildContext context) {
    // Lišta zůstává průhledná i při scrollu -- obsah se u horní hrany
    // rozplyne (`TopFadeScrollBehavior`), žádný šedý skleněný pruh.
    final canPop = ModalRoute.of(context)?.canPop ?? false;
    return AppBar(
      automaticallyImplyLeading: false,
      leading: canPop ? const Center(child: GlassBackButton()) : null,
      title: Text(title),
      actions: actions,
      bottom: bottom,
    );
  }

  @override
  Size get preferredSize => Size.fromHeight(kToolbarHeight + (bottom?.preferredSize.height ?? 0));
}
