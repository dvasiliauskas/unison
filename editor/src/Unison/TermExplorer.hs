{-# Language RecordWildCards #-}
{-# Language OverloadedStrings #-}
{-# Language ScopedTypeVariables #-}

module Unison.TermExplorer where

import Control.Monad.IO.Class
import Data.Either
import Data.List
import Data.Map (Map)
import Data.Maybe
import Data.Semigroup
import Reflex.Dom
import Unison.Metadata (Metadata,Query(..))
import Unison.Node (Node,SearchResults,LocalInfo)
import Unison.Node.MemNode (V)
import Unison.Paths (Path)
import Unison.Reference (Reference)
import Unison.Symbol (Symbol)
import Unison.Term (Term)
import Unison.Type (Type)
import qualified Data.Map as Map
import qualified Data.Text as Text
import qualified Unison.Dimensions as Dimensions
import qualified Unison.Doc as Doc
import qualified Unison.DocView as DocView
import qualified Unison.Explorer as Explorer
import qualified Unison.LiteralParser as LiteralParser
import qualified Unison.Node as Node
import qualified Unison.Note as Note
import qualified Unison.Parser as Parser
import qualified Unison.Signals as Signals
import qualified Unison.Term as Term
import qualified Unison.Typechecker as Typechecker
import qualified Unison.View as View
import qualified Unison.Views as Views

data S =
  S { metadata :: Map Reference (Metadata V Reference)
    , lastResults :: Maybe (SearchResults V Reference (Term V))
    , nonce :: Int }

instance Semigroup S where
  (S md1 r1 id1) <> (S md2 r2 id2) =
    S (Map.unionWith const md2 md1)
      (if id2 > id1 then r2 else r1)
      (id1 `max` id2)

type Advance = Bool

data Action
  = Replace Path (Term V)
  | Step Path
  | Eval Path

make :: forall t m . (MonadWidget t m, Reflex t)
     => Node IO V Reference (Type V) (Term V)
     -> Event t Int
     -> Event t (LocalInfo (Term V) (Type V))
     -> Dynamic t S
     -> Dynamic t Path
     -> Dynamic t (Term V)
     -> m (Event t S, Event t (Maybe (Action,Advance)))
make node keydown localInfo s paths terms =
  let
    parse _ _ Nothing _ = []
    parse lookup path (Just (Node.LocalInfo{..})) txt = case Parser.run LiteralParser.term txt of
      Parser.Succeed ts n | all (\c -> c == ' ' || c == ',') (drop n txt) ->
        ts >>= \tm ->
          if isRight (Typechecker.check' tm localAdmissibleType)
          then [formatResult lookup tm (Replace path tm, False) Right]
          else [formatResult lookup tm () Left]
      _ -> []
    processQuery s localInfo txt selection = do
      searches <- id $
        let k (S {..}) = do path <- sample (current paths);
                            pure $ formatSearch (Views.lookupSymbol metadata) path lastResults
        in mapDynM k s
      metadatas <- mapDyn metadata s
      lookupSymbols <- mapDyn Views.lookupSymbol metadatas
      locals <- Signals.combineDyn3 formatLocals lookupSymbols paths localInfo
      literals <- Signals.combineDyn4 parse lookupSymbols paths localInfo txt
      -- todo - other actions
      keyed <- mconcatDyn [locals, searches, literals]
      let trimEnd = reverse . dropWhile (== ' ') . reverse
      let f possible txt = let txt' = trimEnd txt in filter (isPrefixOf txt' . fst) possible
      filtered <- combineDyn f keyed txt
      pure $
        let
          p (txt, (_,_)) | any (== ';') txt = pure (Just Explorer.Cancel)
          p (txt, (_,_)) | isSuffixOf "  " txt = fmap k <$> sample selection
            where k (a,_) = Explorer.Accept (a,True) -- ending with two spaces is an accept+advance
          p (txt, (rs,textUpdate)) = do
            s <- sample (current s)
            term <- sample (current terms)
            path <- sample (current paths)
            req <- pure $ do
              info <- sample (current localInfo)
              lastResults@Node.SearchResults{..} <- liftIO . Note.run $
                Node.search node
                  term
                  path
                  10
                  (Query (Text.pack txt))
                  (Node.localAdmissibleType <$> info)
              pure $ S (Map.fromList references) (Just lastResults) (nonce s + 1)
            let finish rs n = if textUpdate then Just (Explorer.Request req rs) else Just (Explorer.Results rs n)
            pure $ case lastResults s of
              Nothing -> finish rs 0
              Just results ->
                if resultsComplete results && isPrefixOf (queryString $ Node.query results) txt
                then finish rs (additionalResults results)
                else Just (Explorer.Results rs (additionalResults results))
        in
        push p $ attachDyn txt (updated filtered `Signals.coincides` updated txt)
    formatLocalInfo (i@Node.LocalInfo{..}) = i <$ do
      name <- Views.lookupSymbol . metadata <$> sample (current s)
      let width = Dimensions.Width 400
      elClass "div" "explorer-local-info" $ do
        _ <- elClass "div" "localType" $ DocView.view width (Views.type' name localType)
        _ <- elClass "div" "localAdmissibleType" $ DocView.view width (Views.type' name localAdmissibleType)
        _ <- elClass "div" "localVariables" $
          traverse (elClass "div" "localVariable" . DocView.view width . Views.term name) localVariables
        pure ()
  in
    Explorer.explorer keydown processQuery (fmap formatLocalInfo localInfo) s

queryString :: Query -> String
queryString (Query s) = Text.unpack s

additionalResults :: Node.SearchResults v h e -> Int
additionalResults = snd . Node.matches

resultsComplete :: Node.SearchResults v h e -> Bool
resultsComplete = (==0) . additionalResults

formatResult :: MonadWidget t m
             => (Reference -> Symbol View.DFO) -> Term V -> a -> (m a -> b) -> (String, b)
formatResult name e as w =
  let doc = Views.term name e
      txt = Text.unpack . Text.concat $ Doc.tokens "\n" (Doc.flow doc)
  in (txt, w (as <$ DocView.view (Dimensions.Width 300) doc))

formatLocals :: MonadWidget t m
             => (Reference -> Symbol View.DFO)
             -> Path
             -> Maybe (LocalInfo (Term V) (Type V))
             -> [(String, Either (m ()) (m (Action,Advance)))]
formatLocals name path results = fromMaybe [] $ go <$> results
  where
  view localType 0 = Term.var' "□" `Term.ann` localType
  view _ n = Term.var' "□" `Term.apps` replicate n Term.blank
  replace localTerm n = localTerm `Term.apps` replicate n Term.blank
  go (Node.LocalInfo {..}) =
    [ formatResult name e ((Replace path e),False) Right | e <- localVariableApplications ] ++
    [ formatResult name (view localType n) (Replace path (replace localTerm n),False) Right | n <- localOverapplications ]

formatSearch :: MonadWidget t m
             => (Reference -> Symbol View.DFO)
             -> Path
             -> Maybe (SearchResults V Reference (Term V))
             -> [(String, Either (m ()) (m (Action,Advance)))]
formatSearch name path results = fromMaybe [] $ go <$> results
  where
  go (Node.SearchResults {..}) =
    [ formatResult name e () Left | e <- fst illTypedMatches ] ++
    [ formatResult name e (Replace path e,False) Right | e <- fst matches ]
