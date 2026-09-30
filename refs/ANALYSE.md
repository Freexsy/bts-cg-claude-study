# Analyse des références — le résultat attendu

**En une phrase :** des vidéos courtes (30–45 s) de motion design d'interface, dans l'esprit d'un
lancement produit Apple ou d'une vidéo SaaS. Elles sont construites en code à partir de vrais
composants UI animés, de typographie cinétique et de morphings, et rythmées par la musique.

Mesures obtenues avec `tools/analyze_reference.py` (rapports complets dans `refs/ref1/analyse/`
et `refs/ref2/analyse/`). Les vidéos et les images extraites ne sont pas versionnées : le dépôt
est public et ce sont des contenus de tiers.

## Les deux références

| | Réf. 1 — @nicolas.scalyx | Réf. 2 — @beingmayy |
|---|---|---|
| Sujet | Promo d'agence web « Scalyx — la vitrine digitale de votre entreprise » | Promo « Apple-style motion graphics » (en anglais) |
| Accroche | Titre TikTok « MOTION DESIGN CLAUDE — je t'envoie le prompt sur Insta » : présentée comme faite avec Claude | — |
| Format | 16:9 incrusté dans un cadre 9:16, sous un titre d'accroche | 16:9 plein cadre |
| Durée utile | ≈ 40 s (+ 4 s d'outro ajoutée par TikTok) | ≈ 33 s (+ 4 s d'outro TikTok) |
| Montage | 4 vraies coupes seulement : 4 longues séquences continues où les éléments se transforment | 9 coupes (≈ 3,3 s par plan), dont 8 sur une attaque du son |
| Son | tempo estimé ≈ 104 BPM | tempo estimé ≈ 120 BPM |
| Densité | un événement animé toutes les 0,73 s (médiane) | un événement toutes les 0,63 s (médiane) |
| Ambiance | sombre premium : fond bleu nuit `#0f1118`, texte `#ecf0f1`, gris `#5c6165`, accent cyan `#35a0af` → `#59c1d0` | claire façon Apple : fonds `#f3f5f9` / `#dcdfde`, noir `#080a12`, couleurs système iOS (bleu `#0169fd`, vert `#67ca67`, orange `#faa569`) |
| Typo | grotesque géométrique propre (type Satoshi / Inter Display), mots-clés en cyan, petits sur-titres en capitales | SF Pro, titres très gras (« MORPHING »), textes courts dans des pills et des bulles |

L'outro TikTok (logo et barre de recherche animés) est ajoutée automatiquement par TikTok : elle ne fait pas partie du style à reproduire.

## Le langage commun (ce qui doit sortir)

1. **L'interface est le personnage principal.** Barre de recherche, cartes, notifications, pills,
   bulles iMessage, compteurs, courbes, maquettes de sites dans un laptop ou une fenêtre de
   navigateur. Chaque élément ressemble à un vrai composant, net et crédible.
2. **Typo cinétique, une idée par phrase.** Des phrases de 3 à 6 mots qui arrivent mot par mot.
   Le mot important change de couleur (« en ligne. », « sur mesure. »), ou il est barré puis
   remplacé (« Vos ~~visiteurs~~ deviennent des clients. »).
3. **Continuité par morphing plutôt que par coupe.** Un élément devient le suivant : le logo
   devient le sur-titre, un bouton rond s'étire en pill « iPhone 17 Pro » puis en carte produit,
   un minuteur devient une Live Activity.
4. **Profondeur.** Des cartes et des sites inclinés en perspective (≈ 8–20°), un arrière-plan
   flou, du flou de mouvement sur les déplacements rapides, une caméra qui avance ou glisse sur
   un mur d'interfaces.
5. **Physique, jamais de linéaire.** Des décélérations longues (ease-out très marqué) pour les
   entrées, des springs avec un léger rebond pour ce qui « pop » (bulles, pills, boutons).
6. **Action puis pause.** Chaque événement s'anime en 0,3–0,6 s, puis on laisse 0,3–1 s pour
   lire. Dans la réf. 1, l'image ne se fige presque jamais : le fond dérive doucement en
   permanence.
7. **Micro-interactions.** Un curseur qui se déplace et clique, une frappe au clavier avec
   autocomplétion, un bouton qui change d'état, des chiffres qui roulent, une courbe qui se
   dessine.

## Décomposition image par image

### Réf. 1 — agence (sombre)

- **Logo → sur-titre (5,57 → 5,90 s).** « Scalyx » monte et rétrécit en 0,33 s, avec du flou de
  mouvement. La vitesse culmine dès la 3e image puis s'étire longuement : c'est un ease-out de
  type expo. « On crée » apparaît pendant le mouvement, ce qui crée un chevauchement.
- **Titre (5,8 → 6,4 s).** Chaque mot monte depuis sa ligne de base à l'intérieur d'un masque,
  avec un léger flou. « la vitrine digitale » (cyan) s'écrit lettre par lettre, à environ
  30 ms par lettre.
- **Maquette (6,2 → 7,3 s).** Un laptop blanc monte du bas de l'écran avec du flou de mouvement
  et se pose en douceur, puis le site à l'écran défile.
- **Compteur (23,3 → 24,2 s).** Les chiffres roulent verticalement comme un compteur
  kilométrique, avec du flou, puis ralentissent jusqu'à « ≈ 20 ». Le mot « prospects » monte au
  moment où le nombre se pose. En parallèle, le témoignage s'allume mot par mot (gris → blanc et
  cyan), et une courbe de croissance se dessine juste après.
- **Récit en 40 s.** Problème (« Vos futurs clients vous cherchent en ligne. » avec une
  recherche Google tapée en direct) → solution (logo, « On crée la vitrine digitale de votre
  entreprise ») → preuves (réalisations en 3D, visibilité sur Google et ChatGPT, notifications
  de demandes, témoignage chiffré) → service (« On s'occupe de tout. ») → appel à l'action
  (« Réservez votre rendez-vous gratuit. » avec un clic sur le bouton) → signature (logo,
  slogan, bandeau défilant de villes et de métiers).
- **Décor.** Fond bleu nuit, un arc d'horizon lumineux très discret en bas du cadre, des murs de
  captures de sites floues en perspective.

### Réf. 2 — Apple-style (clair)

- **Morphing bouton → pill → carte (22,33 → 23,30 s).** Le bouton bleu reste seul au moins 0,2 s. Une
  pill blanche en sort vers la gauche en environ 0,15 s, avec un spring. « iPhone », « 17 » et
  « Pro » entrent un par un par le haut, à environ 70 ms d'écart, et la largeur de la pill suit
  le texte. Ensuite, tout s'incline en 3D : le texte se floute, le bouton s'étire en barre et
  l'iPhone orange apparaît en grossissant (≈ 0,2 s).
- **Autres procédés.** Un titre qui passe du flou au net (« 60 Frames Per Second »), des bulles
  iMessage qui pop avec un rebond, un zoom caméra dans une carte Notes, une traversée de champ de
  recherche avec un gros flou de mouvement, un curseur qui clique, un grand mot « MORPHING » dont
  les lettres se transforment, des emojis.
- **Montage serré et musical.** 8 coupes sur 9 tombent sur une attaque du son. À 120 BPM, un
  temps dure 0,5 s, et les événements s'enchaînent tous les 1 à 2 temps.

## La recette pour la produire avec Claude

- **Outil recommandé : Remotion** (React → MP4, rendu image par image). Il donne un timing exact
  à l'image près (`useCurrentFrame`), des `spring()`, des `interpolate()` avec easing, des
  `<Sequence>` pour structurer les scènes, et une piste audio pour caler les coupes sur le beat.
  CSS permet le flou, la 3D et les masques, SVG les courbes, et `@remotion/motion-blur` le flou
  de mouvement. Remotion est gratuit pour un usage individuel.
- **Format.** Un master en 1920×1080 à 60 i/s (la réf. 2 insiste sur la fluidité 60 fps), puis
  une version 9:16. Soit le 16:9 incrusté sous un titre d'accroche comme dans la réf. 1, soit
  une vraie recomposition en 1080×1920.
- **Bibliothèque de mouvements à coder une fois puis réutiliser :**
  - apparition de mots (masque + montée + flou, 70–100 ms entre les mots) et de lettres ;
  - passage du flou au net ;
  - pill ou carte qui se transforme (morph) ;
  - compteur à rouleaux ;
  - barre de recherche avec frappe et autocomplétion ;
  - curseur qui se déplace et clique (léger écrasement à 0,95) ;
  - carte en 3D avec profondeur de champ ;
  - courbe qui se dessine ;
  - bandeau défilant ;
  - poussée de caméra.
- **Courbes et timing.**
  - Entrées : ease-out expo `cubic-bezier(0.16, 1, 0.3, 1)`.
  - Pops : spring avec un léger rebond (Remotion `damping` ≈ 12–15). Sans rebond :
    `damping: 200`.
  - Sorties : environ 70 % de la durée des entrées.
  - Rythme : un événement en 0,3–0,6 s, puis une pause de 0,3–1 s.
  - Coupes sur le beat : à 120 BPM et 60 i/s, un temps = 30 images.
- **Contrôle qualité.** Passer chaque rendu dans `tools/analyze_reference.py`, puis comparer le
  rythme, les pauses et la palette avec ces mesures. Relire les planches contact et au moins une
  transition image par image (`--range`) avant de livrer.
