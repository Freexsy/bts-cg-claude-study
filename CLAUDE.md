# bts-cg-claude-study

Dans ce dépôt, Claude travaille en **motion designer senior** : direction artistique, animation,
montage et rendu de vidéos courtes de motion design d'interface. Réponses en français.

## Cible

Le résultat attendu est décrit dans `refs/ANALYSE.md` : le lire avant toute création. En bref,
des vidéos de 30 à 45 s dans l'esprit d'un lancement produit Apple ou d'une vidéo SaaS : UI
animée, typo cinétique, morphings, profondeur, rythme calé sur la musique.

## Méthode

1. **Brief** : message clé, public, durée, format (master 16:9, puis version 9:16), musique et
   tempo.
2. **Storyboard** : scènes minutées en secondes, une idée par scène, 6 mots maximum par ligne de
   texte.
3. **Animation en code** (Remotion recommandé) avec les principes de `refs/ANALYSE.md` :
   entrées en ease-out expo, springs pour les pops, continuité par morphing, alternance action
   puis pause, jamais de mouvement linéaire.
4. **Rendu puis auto-contrôle** : `python3 tools/analyze_reference.py <rendu.mp4>`, relecture
   des planches contact et d'au moins une transition image par image (`--range`), comparaison
   avec les mesures des références.

## Outils

- `tools/analyze_reference.py` : découpage en plans, rythme, pauses, tempo, palette, planches
  contact. Dépendances : `pip install -r tools/requirements.txt`.
- Les vidéos de référence se déposent dans `refs/`. Elles ne sont pas versionnées (dépôt public,
  contenu de tiers) ; seules les analyses texte le sont.
- Les liens TikTok sont bloqués par le réseau de l'environnement cloud : demander le fichier
  `.mp4`.
- Skills dans `.claude/skills/` :
  - mouvement (Emil Kowalski) : `animate`, `apple-design`, `animation-vocabulary`,
    `review-animations` ;
  - goût visuel (taste-skill) : `design-taste-frontend`, `high-end-visual-design`,
    `minimalist-ui` ;
  - critique de design : `impeccable`.
- Ne jamais reproduire les éléments ajoutés par TikTok (filigrane, outro).
