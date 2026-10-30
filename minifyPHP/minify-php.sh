#!/bin/bash
# Minification PHP pour CodeKit (hook « PHP : minifier la copie publiée »).
#
# CodeKit lance ce script après avoir publié un fichier .php réglé sur « compile ».
# Il réécrit la COPIE PUBLIÉE avec `php -w` (commentaires et espaces PHP retirés ;
# le HTML, le CSS et le JS intégrés ne sont pas minifiés), puis avec la deuxième passe
# intégrée plus bas (blancs entre les jetons : « $a = [ 'x' => 1 ] » → « $a=['x'=>1] »). La source de _dev/
# n'est jamais écrite : on lit la source, on remplace la copie. Une source qui utilise
# __LINE__ ou __halt_compiler() est laissée non minifiée. Usage local seulement (Mac,
# CodeKit) : en cas d'erreur de syntaxe, le message de php -l est donné en entier.
#
# Variables fournies par CodeKit : CK_INPUT_PATH (source), CK_OUTPUT_PATH (copie publiée),
# CK_PROJECT_ROOT (_dev). Réglages facultatifs :
#   MINIFY_PHP_BIN      binaire PHP à utiliser (sinon : Local, version MINIFY_PHP_VERSION)
#   MINIFY_PHP_VERSION  version de PHP, celle de la production (défaut 8.5)
#   MINIFY_PRIVATE      noms de fichiers à secrets, interdits sous la racine web
# Test à la main :
#   CK_INPUT_PATH=… CK_OUTPUT_PATH=… CK_PROJECT_ROOT=… actions/minify-php.sh
#
# Codes de sortie : 0 minifié ou volontairement laissé, 1 erreur (copie publiée inchangée).

set -u -o pipefail

tmp=""
cleanup() { [ -n "$tmp" ] && rm -f "$tmp" "$tmp.c"; }
trap cleanup EXIT
trap 'echo "minify-php : interrompu, copie publiée inchangée."; exit 1' INT TERM HUP

fail() { echo "minify-php : $*"; exit 1; }

# ─── Deuxième passe : compactage (code PHP intégré) ──────────────────────────────────────
# Retire les blancs entre les jetons du code quand ils ne servent à rien :
# « $a = [ 'x' => 1, 'y' => 2 ]; » devient « $a=['x'=>1,'y'=>2]; ».
# Travaille sur les jetons de PHP (token_get_all avec TOKEN_PARSE), jamais sur le texte :
# les chaînes, le HTML hors <?php ?>, les heredocs et les commentaires ne sont pas touchés.
# Un blanc est gardé (un seul espace) quand le retirer changerait le sens :
#   - entre deux mots : « function f », « return $r », « as $seg », « new \Foo » ;
#   - entre deux signes d'opérateur : « $a - -$b » → « $a- -$b », « $x = -1 » → « $x= -1 » ;
#   - entre un chiffre et un point : « 1 . 'a' » (sinon « 1. » serait un nombre).
# Après un commentaire « // » ou « # » encore présent, le retour à la ligne est gardé.
# Refus (code 1, rien écrit) : fichier illisible ou syntaxe invalide, __LINE__ ou
# __halt_compiler(), jetons du résultat différents de ceux de l'entrée (blancs mis à part).
# Les messages ne citent jamais le contenu du fichier (il peut contenir des secrets).
# Utilisation : compacter_php | "$php" -- fichier.php > sortie.php
compacter_php() {
  cat <<'COMPACTER_PHP'
<?php
declare(strict_types=1);

const COMPACTER_WORD = '/[A-Za-z0-9_\x80-\xff$\\\\]/';
const COMPACTER_SIGNS = '+-.*/%<>=!&|?:^~#@';

/** Texte d'un jeton (tableau [id, texte, ligne] ou caractère seul). */
function compacter_text(array|string $token): string
{
    return is_array($token) ? $token[1] : $token;
}

/** Vrai si un blanc est nécessaire entre le caractère $a (fin du précédent) et $b (début du suivant). */
function compacter_needs_space(string $a, string $b): bool
{
    if (preg_match(COMPACTER_WORD, $a) && preg_match(COMPACTER_WORD, $b)) {
        return true;
    }
    if (str_contains(COMPACTER_SIGNS, $a) && str_contains(COMPACTER_SIGNS, $b)) {
        return true;
    }
    return (ctype_digit($a) && $b === '.') || ($a === '.' && ctype_digit($b));
}

/** Vrai si le code dépend de sa position dans le fichier (__LINE__, __halt_compiler). */
function compacter_position_dependent(array $tokens): bool
{
    foreach ($tokens as $token) {
        if (is_array($token) && ($token[0] === T_LINE || $token[0] === T_HALT_COMPILER)) {
            return true;
        }
    }
    return false;
}

/** Code compacté. */
function compacter_run(array $tokens): string
{
    $out = '';
    $last = count($tokens) - 1;
    for ($i = 0; $i <= $last; $i++) {
        $token = $tokens[$i];
        if (!is_array($token) || $token[0] !== T_WHITESPACE) {
            $out .= compacter_text($token);
            continue;
        }
        if ($i === 0 || $i === $last) {
            continue;
        }
        $previous = $tokens[$i - 1];
        // Commentaire de fin de ligne : le retour à la ligne le termine.
        if (is_array($previous) && $previous[0] === T_COMMENT
            && !str_starts_with($previous[1], '/*')) {
            $out .= "\n";
            continue;
        }
        $a = substr(compacter_text($previous), -1);
        $b = compacter_text($tokens[$i + 1])[0];
        // Balise <?php suivie de son blanc : rien à ajouter.
        if (!str_contains(" \t\r\n\v\f", $a) && compacter_needs_space($a, $b)) {
            $out .= ' ';
        }
    }
    return $out;
}

/** Jetons sans les blancs, un par un (aucun autre jeton, même une balise, n'est normalisé). */
function compacter_signature(array $tokens): Generator
{
    foreach ($tokens as $token) {
        if (is_array($token)) {
            if ($token[0] === T_WHITESPACE) {
                continue;
            }
            yield [$token[0], $token[1]];
        } else {
            yield $token;
        }
    }
}

// Outil en ligne de commande seulement, même s'il se retrouvait un jour sous la racine web.
if (PHP_SAPI !== 'cli') {
    http_response_code(404);
    exit;
}

if ($argc !== 2 || !is_file($argv[1])) {
    fwrite(STDERR, "usage : minify-php.sh (deuxième passe interne)\n");
    exit(2);
}

try {
    $code = @file_get_contents($argv[1]);
    if ($code === false) {
        throw new RuntimeException();
    }
    $tokens = token_get_all($code, TOKEN_PARSE);
    if (compacter_position_dependent($tokens)) {
        fwrite(STDERR, "compacter : code dépendant de sa position, rien écrit\n");
        exit(1);
    }
    $result = compacter_run($tokens);
    $before = compacter_signature($tokens);
    $after = compacter_signature(token_get_all($result, TOKEN_PARSE));
    while ($before->valid() && $after->valid() && $before->current() === $after->current()) {
        $before->next();
        $after->next();
    }
    if ($before->valid() || $after->valid()) {
        throw new RuntimeException();
    }
} catch (Throwable) {
    // Les messages du parseur peuvent contenir des secrets du fichier source.
    fwrite(STDERR, "compacter : lecture, syntaxe ou jetons invalides, rien écrit\n");
    exit(1);
}

echo $result;
COMPACTER_PHP
}

src="${CK_INPUT_PATH:-}"
out="${CK_OUTPUT_PATH:-}"
root="${CK_PROJECT_ROOT:-}"
[ -n "$src" ] && [ -n "$out" ] && [ -n "$root" ] || fail "variables CodeKit absentes, rien fait."

# Chemins résolus (.., liens symboliques, chemins relatifs) avant toute comparaison.
src_r=$(realpath "$src" 2>/dev/null) || fail "source introuvable : $src"
out_r=$(realpath "$out" 2>/dev/null) || fail "copie publiée introuvable : $out"
root_r=$(realpath "$root" 2>/dev/null) || fail "dossier du projet introuvable : $root"
[ -f "$src_r" ] && [ -f "$out_r" ] || fail "source ou copie n'est pas un fichier ordinaire."

# Garde-fou : jamais d'écriture dans _dev/, ni sur la source elle-même.
case "$out_r/" in
  "$root_r"/*) echo "minify-php : $out_r est dans _dev, rien fait."; exit 0 ;;
esac
[ "$src_r" != "$out_r" ] || { echo "minify-php : source = sortie, rien fait."; exit 0; }

name=$(basename "$out_r")

# Fichiers à secrets : jamais sous la racine web (parent de _dev). Le hook ne peut pas
# empêcher CodeKit de les publier, mais il le signale en erreur dans le journal.
webroot=$(dirname "$root_r")
for private in ${MINIFY_PRIVATE:-config.php bsm-config.php bsm-sync.php}; do
  if [ "$name" = "$private" ]; then
    case "$out_r" in
      "$webroot"/*) fail "ALERTE : $name est publié sous la racine web ($out_r). Il doit aller dans app/." ;;
    esac
  fi
done

# PHP de Local, à la version de la production (pas « le plus récent »).
php="${MINIFY_PHP_BIN:-}"
if [ -z "$php" ]; then
  version="${MINIFY_PHP_VERSION:-8.5}"
  php=$(ls -d "$HOME/Library/Application Support/Local/lightning-services"/php-"$version".*/bin/darwin-arm64/bin/php 2>/dev/null | sort -V | tail -1)
fi
[ -n "$php" ] && [ -x "$php" ] || fail "PHP ${MINIFY_PHP_VERSION:-8.5} introuvable, copie laissée non minifiée."

# Source invalide : CodeKit a déjà publié la copie telle quelle ; on le signale.
# Message de php -l en entier : le script ne tourne qu'en local (journal de CodeKit sur le Mac).
lint=$("$php" -l "$src_r" 2>&1) || fail "ERREUR de syntaxe dans $name (copie publiée NON minifiée, et invalide) :
$lint"

# Code qui dépend de sa position (__LINE__, __halt_compiler) : contrôlé sur la SOURCE,
# car php -w déplace déjà les lignes. La copie publiée par CodeKit reste telle quelle.
position=$("$php" -r 'try { foreach (token_get_all(file_get_contents($argv[1]), TOKEN_PARSE) as $t) { if (is_array($t) && ($t[0] === T_LINE || $t[0] === T_HALT_COMPILER)) { echo "oui"; exit; } } echo "non"; } catch (Throwable) { echo "erreur"; }' "$src_r" 2>/dev/null)
case "$position" in
  non) ;;
  oui) echo "minify-php : $name utilise __LINE__ ou __halt_compiler(), copie publiée NON minifiée (voulu)."; exit 0 ;;
  *) fail "analyse de $name impossible, copie publiée non minifiée." ;;
esac

# Permissions actuelles de la copie publiée, gardées telles quelles.
mode=$(stat -f %Lp "$out_r") || fail "permissions de $name illisibles."

tmp=$(mktemp "${out_r}.min.XXXXXX") || fail "fichier temporaire impossible à créer."
"$php" -w "$src_r" > "$tmp" || fail "php -w a échoué sur $name, copie inchangée."
[ -s "$tmp" ] || fail "résultat vide pour $name, copie inchangée."
"$php" -l "$tmp" > /dev/null 2>&1 || fail "résultat invalide pour $name, copie inchangée."

# Deuxième passe : blancs entre les jetons (« $a = [ 'x' => 1 ] » → « $a=['x'=>1] »),
# avec le code PHP intégré plus haut (compacter_php).
# En cas d'échec, on garde le résultat de php -w, déjà valide.
note=""
tmp2="${tmp}.c"
if compacter_php | "$php" -- "$tmp" > "$tmp2" 2>/dev/null && [ -s "$tmp2" ] && "$php" -l "$tmp2" > /dev/null 2>&1; then
  mv -f "$tmp2" "$tmp" || { rm -f "$tmp2"; fail "remplacement du temporaire impossible pour $name, copie inchangée."; }
else
  rm -f "$tmp2"
  note=" (compactage refusé, php -w seul)"
fi
chmod "$mode" "$tmp" || fail "chmod impossible sur le temporaire de $name, copie inchangée."
mv -f "$tmp" "$out_r" || fail "remplacement de $name impossible, copie inchangée."
tmp=""

echo "minify-php : $name $(wc -c < "$src_r" | tr -d ' ') → $(wc -c < "$out_r" | tr -d ' ') octets$note"
