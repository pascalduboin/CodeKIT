# minifyPHP : minification PHP pour CodeKit

Hook [CodeKit](https://codekitapp.com) qui minifie les fichiers `.php` **au moment de leur publication**.
La source, dans `_dev/`, n'est jamais modifiée : seule la copie publiée est réécrite.

Exemple :

```php
<?php
// Commentaire à retirer
$tableau = [ 'a' => 1, 'b' => 2 ];   /* autre commentaire */
echo $tableau[ 'a' ] + $tableau[ 'b' ];
```

devient

```php
<?php
$tableau=['a'=>1,'b'=>2];echo $tableau['a']+$tableau['b'];
```

Sur un site réel de 27 fichiers : 460 Ko → 336 Ko avec la première passe, **308 Ko** avec les deux.

## Contenu

Un seul fichier : **`minify-php.sh`**, le hook lancé par CodeKit. Il vérifie, minifie et remplace la copie publiée.

C'est un script bash, mais la minification elle-même est confiée à PHP, le seul à comprendre vraiment le code PHP
(commentaires, chaînes, heredocs, HTML intégré). Le code PHP de la deuxième passe est écrit **à l'intérieur** du
script : aucun autre fichier n'est nécessaire. Il faut seulement que PHP soit installé (voir « Réglages »).

## Fonctionnement

1. **Contrôles de sécurité**
   - les chemins sont résolus (`..`, liens symboliques, chemins relatifs) avant toute comparaison ;
   - rien n'est écrit dans `_dev/`, ni sur la source elle-même ;
   - alerte si un fichier à secrets (`config.php`, `bsm-config.php`, `bsm-sync.php`, ou la liste `MINIFY_PRIVATE`)
     est publié sous la racine web.
2. **Vérification de la source** avec `php -l`. En cas d'erreur de syntaxe, le message complet est affiché dans le
   journal de CodeKit et la copie publiée n'est pas minifiée.
3. **Code qui dépend de sa position** : une source qui utilise `__LINE__` ou `__halt_compiler()` est laissée telle
   quelle, volontairement, car la minification déplace les lignes.
4. **Première passe : `php -w`.** Retire les commentaires PHP (`//`, `#`, `/* */`, PHPDoc) et les espaces.
   Le HTML, le CSS et le JavaScript intégrés ne sont pas touchés.
5. **Deuxième passe : le compactage**, intégré au script. Retire les blancs entre les éléments du code
   (`$a = [ 'x' => 1 ]` → `$a=['x'=>1]`). Il travaille sur les éléments reconnus par PHP (`token_get_all`), jamais
   sur le texte brut : chaînes, heredocs et HTML restent intacts. Un espace est gardé quand il est nécessaire
   (`return $r`, `$a- -$b`, `1 . 2`). Le résultat est comparé à l'entrée : si un seul élément diffère, la deuxième
   passe est abandonnée et seule la première est publiée (« compactage refusé » dans le journal).
6. **Remplacement sûr** : le résultat est écrit dans un fichier temporaire, revérifié avec `php -l`, puis remplace la
   copie publiée en gardant ses permissions. En cas d'échec à n'importe quelle étape, la copie publiée reste inchangée
   et le hook s'arrête avec le code 1.

## Installation dans CodeKit

1. Copiez `minify-php.sh` où vous voulez, par exemple dans le dossier `_dev/actions/` de votre projet, et rendez-le
   exécutable si besoin (`chmod +x minify-php.sh`).
2. Dans CodeKit, ouvrez les réglages du projet → **Hooks**, et ajoutez un hook de type **Shell Script** :
   - **Nom** : « PHP : minifier la copie publiée » ;
   - **Condition** : le chemin du fichier se termine par `.php` ; excluez les bibliothèques tierces (leurs
     commentaires peuvent porter une licence ou des annotations utilisées à l'exécution) ;
   - **Script** :

     ```bash
     /bin/bash "/chemin/vers/minify-php.sh"
     ```

3. Réglez les fichiers `.php` à publier sur **Compile**, pas sur **Copy** : CodeKit ne lance aucun hook sur un fichier
   en mode Copy.

À savoir : `codekit refresh` peut désactiver le hook. Vérifiez qu'il est toujours actif après un rafraîchissement.

## Réglages

CodeKit fournit les chemins : `CK_INPUT_PATH` (source), `CK_OUTPUT_PATH` (copie publiée) et `CK_PROJECT_ROOT`
(dossier `_dev`). Réglages facultatifs, à définir dans le hook :

| Variable | Rôle | Défaut |
| --- | --- | --- |
| `MINIFY_PHP_VERSION` | Version de PHP à utiliser : prenez celle du serveur de production | `8.5` |
| `MINIFY_PHP_BIN` | Chemin d'un binaire PHP précis | le PHP de [Local](https://localwp.com) à la version demandée |
| `MINIFY_PRIVATE` | Noms des fichiers à secrets, interdits sous la racine web | `config.php bsm-config.php bsm-sync.php` |

Exemple pour PHP 8.4 :

```bash
MINIFY_PHP_VERSION=8.4 /bin/bash "/chemin/vers/minify-php.sh"
```

## Essai à la main

```bash
CK_INPUT_PATH=_dev/index.php CK_OUTPUT_PATH=index.php CK_PROJECT_ROOT=_dev ./minify-php.sh
```

Le hook affiche par exemple `minify-php : index.php 4120 → 2380 octets`.

| Code de sortie | Signification |
| --- | --- |
| `0` | Fichier minifié, ou volontairement laissé tel quel |
| `1` | Erreur : la copie publiée est inchangée et le message explique pourquoi |

## Limites

- Une erreur PHP sur le site cite un numéro de ligne qui ne correspond pas à la source : reproduisez-la depuis `_dev/`.
- Le gain porte sur la taille des fichiers sur le serveur et lors des transferts. Le PHP est exécuté par le serveur :
  le navigateur ne télécharge pas moins de données.
- Si la source contient une erreur de syntaxe, CodeKit a déjà publié la copie telle quelle avant le hook. Le hook
  ne peut que signaler l'erreur.
- Le hook fonctionne sur macOS, l'environnement de CodeKit.
