{-# LANGUAGE ExplicitForAll #-}
{-# LANGUAGE TupleSections #-}

-- | After the document is parsed, before getting executed the AST is
--   transformed into a similar, simpler AST. This module is responsible for
--   this transformation.
module Language.GraphQL.AST.Transform
    ( document
    ) where

import Control.Arrow (first)
import Control.Monad (foldM, unless)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Reader (ReaderT, ask, runReaderT)
import Control.Monad.Trans.State (StateT, evalStateT, gets, modify)
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap
import qualified Data.List.NonEmpty as NonEmpty
import Data.Sequence (Seq, (<|), (><))
import qualified Language.GraphQL.AST as Full
import qualified Language.GraphQL.AST.Core as Core
import qualified Language.GraphQL.Execute.Directive as Directive
import qualified Language.GraphQL.Schema as Schema

-- | Associates a fragment name with a list of 'Core.Field's.
data Replacement = Replacement
    { fragments :: HashMap Core.Name Core.Fragment
    , fragmentDefinitions :: HashMap Full.Name Full.FragmentDefinition
    }

type TransformT a = StateT Replacement (ReaderT Schema.Subs Maybe) a

-- | Rewrites the original syntax tree into an intermediate representation used
-- for query execution.
document :: Schema.Subs -> Full.Document -> Maybe Core.Document
document subs document' =
    flip runReaderT subs
        $ evalStateT (collectFragments >> operations operationDefinitions)
        $ Replacement HashMap.empty fragmentTable
  where
    (fragmentTable, operationDefinitions) = foldr defragment mempty document'
    defragment (Full.DefinitionOperation definition) acc =
        (definition :) <$> acc
    defragment (Full.DefinitionFragment definition) acc =
        let (Full.FragmentDefinition name _ _ _) = definition
         in first (HashMap.insert name definition) acc

-- * Operation

operations :: [Full.OperationDefinition] -> TransformT Core.Document
operations operations' = do
    coreOperations <- traverse operation operations'
    lift . lift $ NonEmpty.nonEmpty coreOperations

operation :: Full.OperationDefinition -> TransformT Core.Operation
operation (Full.OperationSelectionSet sels) =
    operation $ Full.OperationDefinition Full.Query mempty mempty mempty sels
-- TODO: Validate Variable definitions with substituter
operation (Full.OperationDefinition Full.Query name _vars _dirs sels) =
    Core.Query name <$> appendSelection sels
operation (Full.OperationDefinition Full.Mutation name _vars _dirs sels) =
    Core.Mutation name <$> appendSelection sels

-- * Selection

selection ::
    Full.Selection ->
    TransformT (Either (Seq Core.Selection) Core.Selection)
selection (Full.SelectionField field') =
    maybe (Left mempty) (Right . Core.SelectionField) <$> field field'
selection (Full.SelectionFragmentSpread fragment) =
    maybe (Left mempty) (Right . Core.SelectionFragment)
    <$> fragmentSpread fragment
selection (Full.SelectionInlineFragment fragment) =
    inlineFragment fragment

appendSelection ::
    Traversable t =>
    t Full.Selection ->
    TransformT (Seq Core.Selection)
appendSelection = foldM go mempty
  where
    go acc sel = append acc <$> selection sel
    append acc (Left list) = list >< acc
    append acc (Right one) = one <| acc

directives :: [Full.Directive] -> TransformT [Core.Directive]
directives = traverse directive
  where
    directive (Full.Directive directiveName directiveArguments) =
        Core.Directive directiveName <$> arguments directiveArguments

-- * Fragment replacement

-- | Extract fragment definitions into a single 'HashMap'.
collectFragments :: TransformT ()
collectFragments = do
    fragDefs <- gets fragmentDefinitions
    let nextValue = head $ HashMap.elems fragDefs
    unless (HashMap.null fragDefs) $ do
        _ <- fragmentDefinition nextValue
        collectFragments

inlineFragment ::
    Full.InlineFragment ->
    TransformT (Either (Seq Core.Selection) Core.Selection)
inlineFragment (Full.InlineFragment type' directives' selectionSet) = do
    fragmentDirectives <- Directive.selection <$> directives directives'
    case fragmentDirectives of
        Nothing -> pure $ Left mempty
        _ -> do
            fragmentSelectionSet <- appendSelection selectionSet
            pure $ maybe Left selectionFragment type' fragmentSelectionSet
  where
    selectionFragment typeName = Right
        . Core.SelectionFragment
        . Core.Fragment typeName

fragmentSpread :: Full.FragmentSpread -> TransformT (Maybe Core.Fragment)
fragmentSpread (Full.FragmentSpread name directives') = do
    spreadDirectives <- Directive.selection <$> directives directives'
    fragments' <- gets fragments
    fragment <- maybe lookupDefinition liftJust (HashMap.lookup name fragments')
    pure $ fragment <$ spreadDirectives 
  where
    lookupDefinition = do
        fragmentDefinitions' <- gets fragmentDefinitions
        found <- lift . lift $ HashMap.lookup name fragmentDefinitions'
        fragmentDefinition found

fragmentDefinition ::
    Full.FragmentDefinition ->
    TransformT Core.Fragment
fragmentDefinition (Full.FragmentDefinition name type' _ selections) = do
    modify deleteFragmentDefinition
    fragmentSelection <- appendSelection selections
    let newValue = Core.Fragment type' fragmentSelection
    modify $ insertFragment newValue
    liftJust newValue
  where
    deleteFragmentDefinition (Replacement fragments' fragmentDefinitions') =
        Replacement fragments' $ HashMap.delete name fragmentDefinitions'
    insertFragment newValue (Replacement fragments' fragmentDefinitions') =
        let newFragments = HashMap.insert name newValue fragments'
         in Replacement newFragments fragmentDefinitions'

field :: Full.Field -> TransformT (Maybe Core.Field)
field (Full.Field alias name arguments' directives' selections) = do
    fieldArguments <- traverse argument arguments'
    fieldSelections <- appendSelection selections
    fieldDirectives <- Directive.selection <$> directives directives'
    let field' = Core.Field alias name fieldArguments fieldSelections
    pure $ field' <$ fieldDirectives

arguments :: [Full.Argument] -> TransformT Core.Arguments
arguments = fmap Core.Arguments . foldM go HashMap.empty
  where
    go arguments' argument' = do
        (Core.Argument name value') <- argument argument'
        return $ HashMap.insert name value' arguments'

argument :: Full.Argument -> TransformT Core.Argument
argument (Full.Argument n v) = Core.Argument n <$> value v

value :: Full.Value -> TransformT Core.Value
value (Full.Variable n) = do
    substitute' <- lift ask
    lift . lift $ substitute' n
value (Full.Int i) = pure $ Core.Int i
value (Full.Float f) = pure $ Core.Float f
value (Full.String x) = pure $ Core.String x
value (Full.Boolean b) = pure $ Core.Boolean b
value Full.Null = pure   Core.Null
value (Full.Enum e) = pure $ Core.Enum e
value (Full.List l) =
    Core.List <$> traverse value l
value (Full.Object o) =
    Core.Object . HashMap.fromList <$> traverse objectField o

objectField :: Full.ObjectField -> TransformT (Core.Name, Core.Value)
objectField (Full.ObjectField name value') = (name,) <$> value value'

liftJust :: forall a. a -> TransformT a
liftJust = lift . lift . Just
