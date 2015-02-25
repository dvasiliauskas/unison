module Unison.View (Env, key, layout, L) where

import Array
import Color
import Debug
import Elmz.Distance as Distance
import Elmz.Layout (Layout)
import Elmz.Layout as L
import List
import List ((::))
import Graphics.Element as E
import Maybe
import Unison.Reference as R
import Unison.Hash (Hash)
import Unison.Metadata (Metadata, Fixity)
import Unison.Metadata as Metadata
import Unison.Styles (codeText)
import Unison.Styles as Styles
import Unison.Term (..)
import Unison.Term as Term
import Unison.Type as Type
import Unison.Path (..)
import Unison.Path as Path
import String
import Text
type alias E = Path.E
type alias Path = Path.Path -- to avoid conflict with Graphics.Collage.Path

type alias L = { path : Path, selectable : Bool }

type alias Env =
  { rootMetadata   : Metadata
  , availableWidth : Int
  , metadata       : R.Reference -> Metadata
  , overrides      : Path -> Maybe (Layout L)
  , overall        : Term }

resolveLocal : String -> Metadata -> Path -> Term -> Metadata.Symbol
resolveLocal notfound md p e =
  let sym = Metadata.anonymousSymbol
  in (boundAt p e `Maybe.andThen` Metadata.localSymbol md) |>
     Maybe.withDefault { sym | name <- notfound }

key : { tl | rootMetadata : Metadata, metadata : R.Reference -> Metadata, overall : Term }
   -> { path : Path, term : Term }
   -> String
key env cur = case cur.term of
  Blank -> "_"
  Var v -> (resolveLocal ("v"++toString v) env.rootMetadata cur.path env.overall).name
  Lit (Number n) -> toString n
  Lit (Str s) -> "\"" ++ toString s ++ "\""
  Lit (Distance d) -> toString d
  Ref r -> Metadata.firstName "anonymous" (env.metadata r)
  App f arg -> key env { path = cur.path `snoc` Fn, term = f } ++
               key env { path = cur.path `snoc` Arg, term = arg }
  Ann e t -> key env { cur | term <- e }
  Vector terms ->
    let ki i term = key env { path = cur.path `snoc` Index i, term = term }
    in "[" ++ String.join "," (Array.toList (Array.indexedMap ki terms)) ++ "]"
  Lam v body -> key env { path = cur.path `snoc` Body, term = body }

{-|

  Layout proceeds in phases:

  1. Traverse the term, find all panels / cells, and compute hashes for all
  2. Build mapping from path to hash - for each panel / cell path, what is its hash
  3. For each panel / cell, compute its dependencies, Dict Hash [Hash]

  At this point, we have a dependency graph for the root panel.

  4. For each panel / cell, if it is marked reactive, as in `cell reactive x`,
     if `x` is a closed term, add it to list of paths that need evaluation.
  5. Send all terms needing evaluation to the node. Node replies with a
     Dict Path Term which editor will splice in.
     (optimization - evaluate some terms locally when possible)

  At this point, we have a fully resolved term tree.

  6. We traverse the resolved tree, applying special layout forms, and building
     up an 'overrides' map `Dict Path (Layout L)`.
     a. This gives us
  7. Finally, we invoke the regular Term.layout function, passing it the overrides map.

  Can be smarter about how we do updates, avoid needless recomputation.

  cell : (a -> Layout) -> a -> a
  vflow : [Layout] -> Layout
  fn : (Layout -> Layout) -> (a -> b) -> Layout

  cell (fn (\x -> vflow [x, hline])) sqrt 23

  panel vflow [panel source 12, panel source "hi", panel reactive #af789de]
  need to
  don't do any evaluation during layout, up to user to evaluate beforehand
  panel vflow (map blah [0..100]) is problematic, doing arbitrary computation at layout time
  but we have to do this for cases like `panel reactive (2 + 2)`

specialLayout : Path -> Term -> Maybe (Layout L)
specialLayout at e = case e of
  -- panel : (a -> Layout) -> a -> Layout
  App (App (Builtin "Unison.Layout.Panel") f) r ->
    interpretLayout f r
  -- cell : (a -> Layout) -> a -> a
  _ -> Nothing


interpretLayout : Path -> Term -> Term -> Maybe (Layout L)
interpretLayout at f e = case f of
  Builtin "Unison.Layout.hflow" -> case e of
  -- panel vflow [panel source 12, panel source "woot"]

-}

todo : a
todo = todo

-- use overrides for

tag path = { path = path, selectable = True }
utag path = { path = path, selectable = False }

space = codeText " "
spaces n =
  if n <= 0 then E.empty else codeText (String.padLeft (n*2) ' ' "")
space2 = codeText "  "

indentWidth = E.widthOf space2

paren : Bool -> { path : Path, term : Term } -> Layout L -> Layout L
paren parenthesize cur e =
  if parenthesize
  then let t = tag cur.path
           opening = L.embed t (codeText "(")
           closing = L.embed t (codeText ")")
           botY = L.heightOf e - L.heightOf closing
           topOpen = L.container t (L.widthOf opening) (L.heightOf e) (L.Pt 0 0) opening
           bottomClose = L.container t (L.widthOf opening) (L.heightOf e) (L.Pt 0 botY) closing
       in L.horizontal t [topOpen, e, bottomClose]
  else e

layout : Term -- term to render
      -> Env
      -> Layout L
layout expr env =
  impl env True 0 env.availableWidth { path = [], term = expr }

impl : Env
    -> Bool
    -> Int
    -> Int
    -> { path : Path, term : Term }
    -> Layout { path : Path, selectable : Bool }
impl env allowBreak ambientPrec availableWidth cur =
  case env.overrides cur.path of
    Just l -> l
    Nothing -> case cur.term of
      Embed l -> l
      Var n -> codeText (resolveLocal ("v"++toString n) env.rootMetadata cur.path env.overall).name
            |> L.embed (tag cur.path)
      Ref h -> codeText (Metadata.firstName (R.toKey h) (env.metadata h)) |> L.embed (tag cur.path)
      Blank -> Styles.blank |> L.embed (tag cur.path)
      Lit (Number n) -> Styles.numericLiteral (toString n) |> L.embed (tag cur.path)
      Lit (Str s) -> Styles.stringLiteral ("\"" ++ s ++ "\"") |> L.embed (tag cur.path)
      Ann e t -> let ann = Styles.codeText (" : " ++ Type.key env t)
                 in L.beside (tag cur.path)
                             (impl env allowBreak 9 (availableWidth - E.widthOf ann) { cur | term <- e })
                             (L.embed (tag cur.path) ann)
      _ -> case builtins env allowBreak ambientPrec availableWidth cur of
        Just l -> l
        Nothing -> let space' = L.embed (tag cur.path) space in
          case break env env.rootMetadata env.metadata cur.path cur.term of
            Prefix f args ->
              let f' = impl env False 9 availableWidth f
                  lines = f' :: List.map (impl env False 10 0) args
                  unbroken = L.intersperseHorizontal space' lines
                          |> paren (ambientPrec > 9) cur
              in if not allowBreak || L.widthOf unbroken < availableWidth
                 then unbroken
                 else let args' = List.map (impl env True 10 (availableWidth - L.widthOf f' - L.widthOf space')) args
                               |> L.vertical (tag cur.path)
                      in L.intersperseHorizontal space' [f',args']
                      |> paren (ambientPrec > 9) cur
            Operators leftAssoc prec hd tl ->
              let f (op,r) l = L.intersperseHorizontal space' [ l, impl env False 10 0 op, impl env False rprec 0 r ]
                  unbroken = List.foldl f (impl env False lprec 0 hd) tl
                          |> paren (ambientPrec > 9) cur
                  lprec = if leftAssoc then prec else 1+prec
                  rprec = if leftAssoc then 1+prec else prec
                  bf (op,r) l =
                    let op' = impl env False 10 0 op
                        remWidth = availableWidth - L.widthOf op' - L.widthOf space'
                    in L.above (tag cur.path) l <|
                       L.intersperseHorizontal space' [op', impl env True rprec remWidth r ]
              in if not allowBreak || L.widthOf unbroken < availableWidth
                 then unbroken
                 else List.foldl bf (impl env True lprec (availableWidth - indentWidth) hd) tl
                      |> paren (ambientPrec > 9) cur
            Lambda args body ->
              let argLayout = List.map (impl env False 0 0) args ++ [L.embed (tag cur.path) (codeText "→")]
                           |> L.intersperseHorizontal space'
                  unbroken = L.intersperseHorizontal space' [argLayout, impl env False 0 0 body]
                          |> paren (ambientPrec > 0) cur
              in if not allowBreak || L.widthOf unbroken < availableWidth
                 then unbroken
                 else L.above (tag cur.path)
                        argLayout
                        (L.horizontal (tag cur.path) [ space', space', impl env True 0 (availableWidth - indentWidth) body])
                      |> paren (ambientPrec > 0) cur
            Bracketed es ->
              let unbroken = Styles.cells (tag cur.path) (codeText "[]") (List.map (impl env False 0 0) es)
              in if not allowBreak || L.widthOf unbroken < availableWidth || List.length es < 2
              then unbroken
              else Styles.verticalCells (tag cur.path) (codeText "[]")
                                        (List.map (impl env True 0 (availableWidth - 4)) es) -- account for cell border

type Break a
  = Prefix a (List a)          -- `Prefix f [x,y,z] == f x y z`
  | Operators Bool Int a (List (a,a)) -- `Operators False x [(+,y), (+,z)] == (x + y) + z`
                                 -- `Operators True x [(^,y), (^,z)] == x ^ (y ^ z)`
  | Bracketed (List a)        -- `Bracketed [x,y,z] == [x,y,z]`
  | Lambda (List a) a          -- `Lambda [x,y,z] e == x -> y -> z -> e`

break : Env
    -> Metadata
    -> (R.Reference -> Metadata)
    -> Path
    -> Term
    -> Break { path : Path, term : Term }
break env rootMd md path expr =
  let prefix f acc path = case f of
        App f arg -> prefix f ({ path = path `snoc` Arg, term = arg } :: acc) (path `snoc` Fn)
        _ -> Prefix { path = path, term = f } acc
      opsL o prec e acc path = case e of
        App (App op l) r ->
          if op == o
          then
            let hd = (
              { path = path `append` [Fn,Fn], term = op },
              { path = path `snoc` Arg, term = r })
            in opsL o prec l (hd :: acc) (path `append` [Fn,Arg])
          else Operators False prec { path = path, term = e} acc
        _ -> Operators False prec { path = path, term = e } acc
      opsR o prec e path = case e of
        App (App op l) r ->
          if op == o
          then case opsR o prec r (path `snoc` Arg) of
            Operators _ prec hd tl ->
              let tl' = ({ path = path `append` [Fn,Fn], term = op }, hd) :: tl
              in Operators True prec { path = path `append` [Fn,Arg], term = l} tl'
          else Operators True prec { path = path, term = e} []
        _ -> Operators True prec { path = path, term = e } []
  in case expr of
    Vector xs -> xs
              |> Array.indexedMap (\i a -> { path = path `snoc` Index i, term = a })
              |> Array.toList
              |> Bracketed
    App (App op l) r ->
      let sym = case op of
        Ref h -> Metadata.firstSymbol (R.toKey h) (md h)
        Var v -> resolveLocal ("v"++toString v) rootMd path env.overall
        _ -> Metadata.anonymousSymbol
      in case sym.fixity of
        Metadata.Prefix -> prefix (App (App op l) r) [] path -- not an operator chain, fall back
        Metadata.InfixL -> opsL op sym.precedence (App (App op l) r) [] path -- left associated operator chain
        Metadata.InfixR -> opsR op sym.precedence (App (App op l) r) path
    Lam v body -> case body of -- audit this
      Lam _ _ -> let trim p = { p | path <- path } in case break env rootMd md (path `snoc` Body) body of
        Lambda args body2 -> Lambda ({ path = path, term = Var v } :: args) body2
        _ -> Lambda [{path = path, term = Var v }] { path = path `snoc` Body, term = body }
      _ -> Lambda [{path = path, term = Var v }] { path = path `snoc` Body, term = body }
    _ -> prefix expr [] path



-- denotes a function a -> Layout
{-

panel (f p q r) x evaluates x, and any arguments to `f` (p, q, r)

hide : View a
spacer : Relative -> Absolute -> View ()
color : Color -> View Panel
palette : View Color
rgb : Int -> Int -> Int -> Color
source : View a
text : Style -> View String
textboxt : Alignment -> Distance -> Style -> View String
reactive : View a -> View a
fn : (Panel -> Panel) -> View (a -> b)
cell (fn f)
horizontal : View [Panel]
wrap : View [Panel]
vertical : View [Panel]
fit-width : Distance -> View a -> View a
container : Distance -> Distance -> (Distance,Distance) -> View a ->

-- set amount of padding size of top,right,bottom,left
pad : Distance -> Distance -> Distance -> Distance -> View a -> View a
view : View Panel
panel : View a -> a -> Panel
cell : View a -> a -> a
Text.{left, right, center, justify} : Alignment

panel vertical [
  panel source "hello",
  panel source (1 + 23)
]
panel view (panel blah x)
-}

-- eventually, this should return a list of paths needing evaluation
-- Flow a = Int -> Layout a

builtins : Env -> Bool -> Int -> Int -> { term : Term, path : Path } -> Maybe (Layout L)
builtins env allowBreak availableWidth ambientPrec cur =
  let
    t = tag (cur.path `snoc` Arg)
    go v e = case v of
      App (Ref (R.Builtin "View.color")) c -> case c of
        App (App (App (App (Ref (R.Builtin "Color.rgba")) (Lit (Number r))) (Lit (Number g))) (Lit (Number b))) (Lit (Number a)) ->
          let c' = Color.rgba (floor r) (floor g) (floor b) a
          in Just (L.fill c' (impl env allowBreak ambientPrec availableWidth { path = cur.path `snoc` Arg, term = e }))
        _ -> Nothing
      App (Ref (R.Builtin "View.fit-width")) (Lit (Term.Distance d)) ->
        let rem = availableWidth `min` floor (Distance.pixels d (toFloat availableWidth))
        in Just (impl env allowBreak ambientPrec rem { path = cur.path `snoc` Arg, term = e })
      Ref (R.Builtin "View.hide") -> Just (L.empty t)
      Ref (R.Builtin "View.horizontal") -> case e of
        Vector es -> Nothing -- todo more complicated, as we need to do sequencing
        _ -> Nothing
      Ref (R.Builtin "View.swatch") -> case e of
        App (App (App (App (Ref (R.Builtin "Color.rgba")) (Lit (Number r))) (Lit (Number g))) (Lit (Number b))) (Lit (Number a)) ->
          let c = Color.rgba (floor r) (floor g) (floor b) a
          in Just (L.embed t (Styles.swatch c))
        _ -> Nothing
      Ref (R.Builtin "View.source") ->
        Just (impl env allowBreak ambientPrec availableWidth { path = cur.path `snoc` Arg, term = e })
      App (App (Ref (R.Builtin "View.spacer")) (Lit (Term.Distance w))) (Lit (Term.Number h)) ->
        let w' = availableWidth `min` floor (Distance.pixels w (toFloat availableWidth))
            h' = ceiling h
        in Just (L.embed t (E.spacer w' h'))
      App (Ref (R.Builtin "View.text")) style -> case e of
        -- todo, actually interpret style
        Lit (Str s) -> Just (L.embed t (Text.leftAligned (Text.style Text.defaultStyle (Text.fromString s))))
      App (App (App (Ref (R.Builtin "View.textbox")) (Ref (R.Builtin alignment))) (Lit (Term.Distance d))) style ->
        case e of
          Lit (Str s) ->
            -- todo, actually interpret style
            let f = case alignment of
                      "Text.left"    -> Text.leftAligned
                      "Text.right"   -> Text.rightAligned
                      "Text.center"  -> Text.centered
                      "Text.justify" -> Text.justified
                e = f (Text.style Text.defaultStyle (Text.fromString s))
                rem = availableWidth `max` floor (Distance.pixels d (toFloat availableWidth))
                e' = if E.widthOf e > rem then E.width rem e else e
            in Just (L.embed t e')
          _ -> Nothing
      Ref (R.Builtin "View.vertical") -> case e of
        Vector es ->
          let f i e = impl env allowBreak ambientPrec availableWidth
                        { path = cur.path `append` [Arg, Path.Index i], term = e }
          in Just (L.vertical (tag (cur.path `snoc` Arg)) (List.indexedMap f (Array.toList es)))
      Ref (R.Builtin "View.id") -> builtins env allowBreak availableWidth ambientPrec { path = cur.path `snoc` Arg, term = e }
      Ref (R.Builtin "View.wrap") -> case e of
        Vector es -> Nothing -- todo more complicated, as we need to do sequencing
        _ -> Nothing
      _ -> Nothing
  in case cur.term of
    App (App (App (Ref (R.Builtin "View.cell")) (App (Ref (R.Builtin "View.function1")) (Lam arg body))) f) e ->
      -- all paths will point to `f` aside from `e`
      let eview = close (Embed (impl env allowBreak 0 availableWidth { path = cur.path `snoc` Arg, term = e }))
          fpath = cur.path `append` [Fn,Arg]
          trim l = if Path.startsWith fpath l.path then { l | path <- cur.path } else l
          g view = impl env allowBreak ambientPrec availableWidth { path = fpath, term = substitute body arg view }
                |> L.map trim
      in Maybe.map g eview
    App (App (Ref (R.Builtin "View.panel")) v) e -> go v e
    App (App (Ref (R.Builtin "View.cell")) v) e -> go v e
    _ -> Nothing
