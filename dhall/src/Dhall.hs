{-# LANGUAGE ApplicativeDo              #-}
{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE DefaultSignatures          #-}
{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE MultiWayIf                 #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE PolyKinds                  #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TupleSections              #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE UndecidableInstances       #-}

{-| Please read the "Dhall.Tutorial" module, which contains a tutorial explaining
    how to use the language, the compiler, and this library
-}

module Dhall
    (
    -- * Input
      input
    , inputWithSettings
    , inputFile
    , inputFileWithSettings
    , inputExpr
    , inputExprWithSettings
    , rootDirectory
    , sourceName
    , startingContext
    , substitutions
    , normalizer
    , defaultInputSettings
    , InputSettings
    , defaultEvaluateSettings
    , EvaluateSettings
    , HasEvaluateSettings
    , detailed

    -- * Decoders
    , Decoder (..)
    , RecordDecoder(..)
    , UnionDecoder(..)
    , Encoder(..)
    , FromDhall(..)
    , Interpret
    , InvalidDecoder(..)
    , ExtractErrors
    , ExtractError(..)
    , Extractor
    , MonadicExtractor
    , typeError
    , extractError
    , toMonadic
    , fromMonadic
    , ExpectedTypeErrors
    , ExpectedTypeError(..)
    , Expector
    , auto
    , genericAuto
    , genericAutoWith
    , InterpretOptions(..)
    , InputNormalizer(..)
    , defaultInputNormalizer
    , SingletonConstructors(..)
    , defaultInterpretOptions
    , bool
    , natural
    , integer
    , scientific
    , double
    , lazyText
    , strictText
    , maybe
    , sequence
    , list
    , vector
    , function
    , functionWith
    , setFromDistinctList
    , setIgnoringDuplicates
    , hashSetFromDistinctList
    , hashSetIgnoringDuplicates
    , Dhall.map
    , hashMap
    , pairFromMapEntry
    , unit
    , void
    , string
    , pair
    , record
    , field
    , union
    , constructor
    , GenericFromDhall(..)

    , ToDhall(..)
    , Inject
    , inject
    , genericToDhall
    , genericToDhallWith
    , RecordEncoder(..)
    , encodeFieldWith
    , encodeField
    , recordEncoder
    , UnionEncoder(..)
    , encodeConstructorWith
    , encodeConstructor
    , unionEncoder
    , (>|<)
    , GenericToDhall(..)

    -- * Miscellaneous
    , DhallErrors(..)
    , showDhallErrors
    , rawInput
    , (>$<)
    , (>*<)

    -- * Re-exports
    , Natural
    , Seq
    , Text
    , Vector
    , Generic
    ) where

import Control.Applicative                  (Alternative, empty, liftA2)
import Control.Exception                    (Exception)
import Control.Monad                        (guard)
import Control.Monad.Trans.State.Strict
import Data.Coerce                          (coerce)
import Data.Either.Validation
    ( Validation (..)
    , eitherToValidation
    , validationToEither
    )
import Data.Fix                             (Fix (..))
import Data.Functor.Contravariant           (Contravariant (..), Op (..), (>$<))
import Data.Functor.Contravariant.Divisible (Divisible (..), divided)
import Data.Hashable                        (Hashable)
import Data.HashMap.Strict                  (HashMap)
import Data.List.NonEmpty                   (NonEmpty (..))
import Data.Map                             (Map)
import Data.Monoid                          ((<>))
import Data.Scientific                      (Scientific)
import Data.Semigroup                       (Semigroup)
import Data.Sequence                        (Seq)
import Data.Text                            (Text)
import Data.Text.Prettyprint.Doc            (Pretty)
import Data.Typeable                        (Proxy (..), Typeable)
import Data.Vector                          (Vector)
import Data.Void                            (Void)
import Data.Word                            (Word16, Word32, Word64, Word8)
import Dhall.Import                         (Imported (..))
import Dhall.Parser                         (Src (..))
import Dhall.Syntax
    ( Chunks (..)
    , DhallDouble (..)
    , Expr (..)
    , RecordField (..)
    , Var (..)
    )
import Dhall.TypeCheck                      (DetailedTypeError (..), TypeError)
import GHC.Generics
import Lens.Family                          (LensLike', view)
import Numeric.Natural                      (Natural)
import Prelude                              hiding (maybe, sequence)
import System.FilePath                      (takeDirectory)

import qualified Control.Applicative
import qualified Control.Exception
import qualified Control.Monad.Trans.State.Strict as State
import qualified Data.Foldable
import qualified Data.Functor.Compose
import qualified Data.Functor.Product
import qualified Data.HashMap.Strict              as HashMap
import qualified Data.HashSet
import qualified Data.List
import qualified Data.List.NonEmpty
import qualified Data.Map
import qualified Data.Maybe
import qualified Data.Scientific
import qualified Data.Semigroup
import qualified Data.Sequence
import qualified Data.Set
import qualified Data.Text
import qualified Data.Text.IO
import qualified Data.Text.Lazy
import qualified Data.Vector
import qualified Data.Void
import qualified Dhall.Context
import qualified Dhall.Core
import qualified Dhall.Import
import qualified Dhall.Map
import qualified Dhall.Parser
import qualified Dhall.Pretty.Internal
import qualified Dhall.Substitution
import qualified Dhall.TypeCheck
import qualified Dhall.Util
import qualified Lens.Family

-- $setup
-- >>> :set -XOverloadedStrings
-- >>> :set -XRecordWildCards
-- >>> import Data.Word (Word8, Word16, Word32, Word64)
-- >>> import Dhall.Pretty.Internal (prettyExpr)

{-| A newtype suitable for collecting one or more errors
-}
newtype DhallErrors e = DhallErrors
   { getErrors :: NonEmpty e
   } deriving (Eq, Functor, Semigroup)

instance (Show (DhallErrors e), Typeable e) => Exception (DhallErrors e)

{-| Render a given prefix and some errors to a string.
-}
showDhallErrors :: Show e => String -> DhallErrors e -> String
showDhallErrors _   (DhallErrors (e :| [])) = show e
showDhallErrors ctx (DhallErrors es) = prefix <> (unlines . Data.List.NonEmpty.toList . fmap show $ es)
  where
    prefix =
        "Multiple errors were encountered" ++ ctx ++ ": \n\
        \                                               \n"

{-| Useful synonym for the `Validation` type used when marshalling Dhall
    expressions
-}
type Extractor s a = Validation (ExtractErrors s a)

{-| Useful synonym for the equivalent `Either` type used when marshalling Dhall
    code
-}
type MonadicExtractor s a = Either (ExtractErrors s a)

{-| Generate a type error during extraction by specifying the expected type
    and the actual type.
    The expected type is not yet determined.
-}
typeError :: Expector (Expr s a) -> Expr s a -> Extractor s a b
typeError expected actual = Failure $ case expected of
    Failure e         -> fmap ExpectedTypeError e
    Success expected' -> DhallErrors $ pure $ TypeMismatch $ InvalidDecoder expected' actual

-- | Turn a `Text` message into an extraction failure
extractError :: Text -> Extractor s a b
extractError = Failure . DhallErrors . pure . ExtractError

{-| Useful synonym for the `Validation` type used when marshalling Dhall
    expressions
-}
type Expector = Validation ExpectedTypeErrors

{-| One or more errors returned when determining the Dhall type of a
    Haskell expression
-}
type ExpectedTypeErrors = DhallErrors ExpectedTypeError

{-| Error type used when determining the Dhall type of a Haskell expression
-}
data ExpectedTypeError = RecursiveTypeError
    deriving (Eq, Show)

instance Exception ExpectedTypeError

instance Show ExpectedTypeErrors where
    show = showDhallErrors " while determining the expected type"

-- | Switches from an @Applicative@ extraction result, able to accumulate errors,
-- to a @Monad@ extraction result, able to chain sequential operations
toMonadic :: Extractor s a b -> MonadicExtractor s a b
toMonadic = validationToEither

-- | Switches from a @Monad@ extraction result, able to chain sequential errors,
-- to an @Applicative@ extraction result, able to accumulate errors
fromMonadic :: MonadicExtractor s a b -> Extractor s a b
fromMonadic = eitherToValidation

{-| One or more errors returned from extracting a Dhall expression to a
    Haskell expression
-}
type ExtractErrors s a = DhallErrors (ExtractError s a)

instance (Pretty s, Pretty a, Typeable s, Typeable a) => Show (ExtractErrors s a) where
    show = showDhallErrors " during extraction"

{-| Extraction of a value can fail for two reasons, either a type mismatch (which should not happen,
    as expressions are type-checked against the expected type before being passed to @extract@), or
    a term-level error, described with a freeform text value.
-}
data ExtractError s a =
    TypeMismatch (InvalidDecoder s a)
  | ExpectedTypeError ExpectedTypeError
  | ExtractError Text

instance (Pretty s, Pretty a, Typeable s, Typeable a) => Show (ExtractError s a) where
  show (TypeMismatch e)      = show e
  show (ExpectedTypeError e) = show e
  show (ExtractError es)     =
      _ERROR <> ": Failed extraction                                                   \n\
      \                                                                                \n\
      \The expression type-checked successfully but the transformation to the target   \n\
      \type failed with the following error:                                           \n\
      \                                                                                \n\
      \" <> Data.Text.unpack es <> "\n\
      \                                                                                \n"

instance (Pretty s, Pretty a, Typeable s, Typeable a) => Exception (ExtractError s a)

{-| Every `Decoder` must obey the contract that if an expression's type matches the
    the `expected` type then the `extract` function must not fail with a type error.
    If not, then this value is returned.

    This value indicates that an invalid `Decoder` was provided to the `input`
    function
-}
data InvalidDecoder s a = InvalidDecoder
  { invalidDecoderExpected   :: Expr s a
  , invalidDecoderExpression :: Expr s a
  }
  deriving (Typeable)

instance (Pretty s, Typeable s, Pretty a, Typeable a) => Exception (InvalidDecoder s a)

_ERROR :: String
_ERROR = "\ESC[1;31mError\ESC[0m"

instance (Pretty s, Pretty a, Typeable s, Typeable a) => Show (InvalidDecoder s a) where
    show InvalidDecoder { .. } =
        _ERROR <> ": Invalid Dhall.Decoder                                               \n\
        \                                                                                \n\
        \Every Decoder must provide an extract function that succeeds if an expression   \n\
        \matches the expected type.  You provided a Decoder that disobeys this contract  \n\
        \                                                                                \n\
        \The Decoder provided has the expected dhall type:                               \n\
        \                                                                                \n\
        \" <> show txt0 <> "\n\
        \                                                                                \n\
        \and it couldn't extract a value from the well-typed expression:                 \n\
        \                                                                                \n\
        \" <> show txt1 <> "\n\
        \                                                                                \n"
        where
          txt0 = Dhall.Util.insert invalidDecoderExpected
          txt1 = Dhall.Util.insert invalidDecoderExpression

-- | @since 1.16
data InputSettings = InputSettings
  { _rootDirectory :: FilePath
  , _sourceName :: FilePath
  , _evaluateSettings :: EvaluateSettings
  }

-- | Default input settings: resolves imports relative to @.@ (the
-- current working directory), report errors as coming from @(input)@,
-- and default evaluation settings from 'defaultEvaluateSettings'.
--
-- @since 1.16
defaultInputSettings :: InputSettings
defaultInputSettings = InputSettings
  { _rootDirectory = "."
  , _sourceName = "(input)"
  , _evaluateSettings = defaultEvaluateSettings
  }

-- | Access the directory to resolve imports relative to.
--
-- @since 1.16
rootDirectory
  :: (Functor f)
  => LensLike' f InputSettings FilePath
rootDirectory k s =
  fmap (\x -> s { _rootDirectory = x }) (k (_rootDirectory s))

-- | Access the name of the source to report locations from; this is
-- only used in error messages, so it's okay if this is a best guess
-- or something symbolic.
--
-- @since 1.16
sourceName
  :: (Functor f)
  => LensLike' f InputSettings FilePath
sourceName k s =
  fmap (\x -> s { _sourceName = x}) (k (_sourceName s))

-- | @since 1.16
data EvaluateSettings = EvaluateSettings
  { _substitutions   :: Dhall.Substitution.Substitutions Src Void
  , _startingContext :: Dhall.Context.Context (Expr Src Void)
  , _normalizer      :: Maybe (Dhall.Core.ReifiedNormalizer Void)
  }

-- | Default evaluation settings: no extra entries in the initial
-- context, and no special normalizer behaviour.
--
-- @since 1.16
defaultEvaluateSettings :: EvaluateSettings
defaultEvaluateSettings = EvaluateSettings
  { _substitutions   = Dhall.Substitution.empty
  , _startingContext = Dhall.Context.empty
  , _normalizer      = Nothing
  }

-- | Access the starting context used for evaluation and type-checking.
--
-- @since 1.16
startingContext
  :: (Functor f, HasEvaluateSettings s)
  => LensLike' f s (Dhall.Context.Context (Expr Src Void))
startingContext = evaluateSettings . l
  where
    l :: (Functor f)
      => LensLike' f EvaluateSettings (Dhall.Context.Context (Expr Src Void))
    l k s = fmap (\x -> s { _startingContext = x}) (k (_startingContext s))

-- | Access the custom substitutions.
--
-- @since 1.30
substitutions
  :: (Functor f, HasEvaluateSettings s)
  => LensLike' f s (Dhall.Substitution.Substitutions Src Void)
substitutions = evaluateSettings . l
  where
    l :: (Functor f)
      => LensLike' f EvaluateSettings (Dhall.Substitution.Substitutions Src Void)
    l k s = fmap (\x -> s { _substitutions = x }) (k (_substitutions s))

-- | Access the custom normalizer.
--
-- @since 1.16
normalizer
  :: (Functor f, HasEvaluateSettings s)
  => LensLike' f s (Maybe (Dhall.Core.ReifiedNormalizer Void))
normalizer = evaluateSettings . l
  where
    l :: (Functor f)
      => LensLike' f EvaluateSettings (Maybe (Dhall.Core.ReifiedNormalizer Void))
    l k s = fmap (\x -> s { _normalizer = x }) (k (_normalizer s))

-- | @since 1.16
class HasEvaluateSettings s where
  evaluateSettings
    :: (Functor f)
    => LensLike' f s EvaluateSettings

instance HasEvaluateSettings InputSettings where
  evaluateSettings k s =
    fmap (\x -> s { _evaluateSettings = x }) (k (_evaluateSettings s))

instance HasEvaluateSettings EvaluateSettings where
  evaluateSettings = id

{-| Type-check and evaluate a Dhall program, decoding the result into Haskell

    The first argument determines the type of value that you decode:

>>> input integer "+2"
2
>>> input (vector double) "[1.0, 2.0]"
[1.0,2.0]

    Use `auto` to automatically select which type to decode based on the
    inferred return type:

>>> input auto "True" :: IO Bool
True

    This uses the settings from 'defaultInputSettings'.
-}
input
    :: Decoder a
    -- ^ The decoder for the Dhall value
    -> Text
    -- ^ The Dhall program
    -> IO a
    -- ^ The decoded value in Haskell
input =
  inputWithSettings defaultInputSettings

{-| Extend 'input' with a root directory to resolve imports relative
    to, a file to mention in errors as the source, a custom typing
    context, and a custom normalization process.

@since 1.16
-}
inputWithSettings
    :: InputSettings
    -> Decoder a
    -- ^ The decoder for the Dhall value
    -> Text
    -- ^ The Dhall program
    -> IO a
    -- ^ The decoded value in Haskell
inputWithSettings settings (Decoder {..}) txt = do
    expected' <- case expected of
        Success x -> return x
        Failure e -> Control.Exception.throwIO e

    let suffix = Dhall.Pretty.Internal.prettyToStrictText expected'
    let annotate substituted = case substituted of
            Note (Src begin end bytes) _ ->
                Note (Src begin end bytes') (Annot substituted expected')
              where
                bytes' = bytes <> " : " <> suffix
            _ ->
                Annot substituted expected'

    normExpr <- inputHelper annotate settings txt

    case extract normExpr  of
        Success x  -> return x
        Failure e -> Control.Exception.throwIO e

{-| Type-check and evaluate a Dhall program that is read from the
    file-system.

    This uses the settings from 'defaultEvaluateSettings'.

    @since 1.16
-}
inputFile
  :: Decoder a
  -- ^ The decoder for the Dhall value
  -> FilePath
  -- ^ The path to the Dhall program.
  -> IO a
  -- ^ The decoded value in Haskell.
inputFile =
  inputFileWithSettings defaultEvaluateSettings

{-| Extend 'inputFile' with a custom typing context and a custom
    normalization process.

@since 1.16
-}
inputFileWithSettings
  :: EvaluateSettings
  -> Decoder a
  -- ^ The decoder for the Dhall value
  -> FilePath
  -- ^ The path to the Dhall program.
  -> IO a
  -- ^ The decoded value in Haskell.
inputFileWithSettings settings ty path = do
  text <- Data.Text.IO.readFile path
  let inputSettings = InputSettings
        { _rootDirectory = takeDirectory path
        , _sourceName = path
        , _evaluateSettings = settings
        }
  inputWithSettings inputSettings ty text

{-| Similar to `input`, but without interpreting the Dhall `Expr` into a Haskell
    type.

    Uses the settings from 'defaultInputSettings'.
-}
inputExpr
    :: Text
    -- ^ The Dhall program
    -> IO (Expr Src Void)
    -- ^ The fully normalized AST
inputExpr =
  inputExprWithSettings defaultInputSettings

{-| Extend 'inputExpr' with a root directory to resolve imports relative
    to, a file to mention in errors as the source, a custom typing
    context, and a custom normalization process.

@since 1.16
-}
inputExprWithSettings
    :: InputSettings
    -> Text
    -- ^ The Dhall program
    -> IO (Expr Src Void)
    -- ^ The fully normalized AST
inputExprWithSettings = inputHelper id

{-| Helper function for the input* function family

@since 1.30
-}
inputHelper
    :: (Expr Src Void -> Expr Src Void)
    -> InputSettings
    -> Text
    -- ^ The Dhall program
    -> IO (Expr Src Void)
    -- ^ The fully normalized AST
inputHelper annotate settings txt = do
    expr  <- Dhall.Core.throws (Dhall.Parser.exprFromText (view sourceName settings) txt)

    let InputSettings {..} = settings

    let EvaluateSettings {..} = _evaluateSettings

    let transform =
               Lens.Family.set Dhall.Import.substitutions   _substitutions
            .  Lens.Family.set Dhall.Import.normalizer      _normalizer
            .  Lens.Family.set Dhall.Import.startingContext _startingContext

    let status = transform (Dhall.Import.emptyStatus _rootDirectory)

    expr' <- State.evalStateT (Dhall.Import.loadWith expr) status

    let substituted = Dhall.Substitution.substitute expr' $ view substitutions settings
    let annot = annotate substituted
    _ <- Dhall.Core.throws (Dhall.TypeCheck.typeWith (view startingContext settings) annot)
    pure (Dhall.Core.normalizeWith (view normalizer settings) substituted)

-- | Use this function to extract Haskell values directly from Dhall AST.
--   The intended use case is to allow easy extraction of Dhall values for
--   making the function `Dhall.Core.normalizeWith` easier to use.
--
--   For other use cases, use `input` from `Dhall` module. It will give you
--   a much better user experience.
rawInput
    :: Alternative f
    => Decoder a
    -- ^ The decoder for the Dhall value
    -> Expr s Void
    -- ^ a closed form Dhall program, which evaluates to the expected type
    -> f a
    -- ^ The decoded value in Haskell
rawInput (Decoder {..}) expr = do
    case extract (Dhall.Core.normalize expr) of
        Success x  -> pure x
        Failure _e -> empty

{-| Use this to provide more detailed error messages

>> input auto "True" :: IO Integer
> *** Exception: Error: Expression doesn't match annotation
>
> True : Integer
>
> (input):1:1

>> detailed (input auto "True") :: IO Integer
> *** Exception: Error: Expression doesn't match annotation
>
> Explanation: You can annotate an expression with its type or kind using the
> ❰:❱ symbol, like this:
>
>
>     ┌───────┐
>     │ x : t │  ❰x❱ is an expression and ❰t❱ is the annotated type or kind of ❰x❱
>     └───────┘
>
> The type checker verifies that the expression's type or kind matches the
> provided annotation
>
> For example, all of the following are valid annotations that the type checker
> accepts:
>
>
>     ┌─────────────┐
>     │ 1 : Natural │  ❰1❱ is an expression that has type ❰Natural❱, so the type
>     └─────────────┘  checker accepts the annotation
>
>
>     ┌───────────────────────┐
>     │ Natural/even 2 : Bool │  ❰Natural/even 2❱ has type ❰Bool❱, so the type
>     └───────────────────────┘  checker accepts the annotation
>
>
>     ┌────────────────────┐
>     │ List : Type → Type │  ❰List❱ is an expression that has kind ❰Type → Type❱,
>     └────────────────────┘  so the type checker accepts the annotation
>
>
>     ┌──────────────────┐
>     │ List Text : Type │  ❰List Text❱ is an expression that has kind ❰Type❱, so
>     └──────────────────┘  the type checker accepts the annotation
>
>
> However, the following annotations are not valid and the type checker will
> reject them:
>
>
>     ┌──────────┐
>     │ 1 : Text │  The type checker rejects this because ❰1❱ does not have type
>     └──────────┘  ❰Text❱
>
>
>     ┌─────────────┐
>     │ List : Type │  ❰List❱ does not have kind ❰Type❱
>     └─────────────┘
>
>
> You or the interpreter annotated this expression:
>
> ↳ True
>
> ... with this type or kind:
>
> ↳ Integer
>
> ... but the inferred type or kind of the expression is actually:
>
> ↳ Bool
>
> Some common reasons why you might get this error:
>
> ● The Haskell Dhall interpreter implicitly inserts a top-level annotation
>   matching the expected type
>
>   For example, if you run the following Haskell code:
>
>
>     ┌───────────────────────────────┐
>     │ >>> input auto "1" :: IO Text │
>     └───────────────────────────────┘
>
>
>   ... then the interpreter will actually type check the following annotated
>   expression:
>
>
>     ┌──────────┐
>     │ 1 : Text │
>     └──────────┘
>
>
>   ... and then type-checking will fail
>
> ────────────────────────────────────────────────────────────────────────────────
>
> True : Integer
>
> (input):1:1

-}
detailed :: IO a -> IO a
detailed =
    Control.Exception.handle handler1 . Control.Exception.handle handler0
  where
    handler0 :: Imported (TypeError Src Void) -> IO a
    handler0 (Imported ps e) =
        Control.Exception.throwIO (Imported ps (DetailedTypeError e))

    handler1 :: TypeError Src Void -> IO a
    handler1 e = Control.Exception.throwIO (DetailedTypeError e)

{-| A @(Decoder a)@ represents a way to marshal a value of type @\'a\'@ from Dhall
    into Haskell

    You can produce `Decoder`s either explicitly:

> example :: Decoder (Vector Text)
> example = vector text

    ... or implicitly using `auto`:

> example :: Decoder (Vector Text)
> example = auto

    You can consume `Decoder`s using the `input` function:

> input :: Decoder a -> Text -> IO a
-}
data Decoder a = Decoder
    { extract  :: Expr Src Void -> Extractor Src Void a
    -- ^ Extracts Haskell value from the Dhall expression
    , expected :: Expector (Expr Src Void)
    -- ^ Dhall type of the Haskell value
    }
    deriving (Functor)

{-| Decode a `Bool`

>>> input bool "True"
True
-}
bool :: Decoder Bool
bool = Decoder {..}
  where
    extract (BoolLit b) = pure b
    extract expr        = typeError expected expr

    expected = pure Bool

{-| Decode a `Natural`

>>> input natural "42"
42
-}
natural :: Decoder Natural
natural = Decoder {..}
  where
    extract (NaturalLit n) = pure n
    extract  expr          = typeError expected expr

    expected = pure Natural

{-| Decode an `Integer`

>>> input integer "+42"
42
-}
integer :: Decoder Integer
integer = Decoder {..}
  where
    extract (IntegerLit n) = pure n
    extract  expr          = typeError expected expr

    expected = pure Integer

{-| Decode a `Scientific`

>>> input scientific "1e100"
1.0e100
-}
scientific :: Decoder Scientific
scientific = fmap Data.Scientific.fromFloatDigits double

{-| Decode a `Double`

>>> input double "42.0"
42.0
-}
double :: Decoder Double
double = Decoder {..}
  where
    extract (DoubleLit (DhallDouble n)) = pure n
    extract  expr                       = typeError expected expr

    expected = pure Double

{-| Decode lazy `Text`

>>> input lazyText "\"Test\""
"Test"
-}
lazyText :: Decoder Data.Text.Lazy.Text
lazyText = fmap Data.Text.Lazy.fromStrict strictText

{-| Decode strict `Text`

>>> input strictText "\"Test\""
"Test"
-}
strictText :: Decoder Text
strictText = Decoder {..}
  where
    extract (TextLit (Chunks [] t)) = pure t
    extract  expr                   = typeError expected expr

    expected = pure Text

{-| Decode a `Maybe`

>>> input (maybe natural) "Some 1"
Just 1
-}
maybe :: Decoder a -> Decoder (Maybe a)
maybe (Decoder extractIn expectedIn) = Decoder extractOut expectedOut
  where
    extractOut (Some e    ) = fmap Just (extractIn e)
    extractOut (App None _) = pure Nothing
    extractOut expr         = typeError expectedOut expr

    expectedOut = App Optional <$> expectedIn

{-| Decode a `Seq`

>>> input (sequence natural) "[1, 2, 3]"
fromList [1,2,3]
-}
sequence :: Decoder a -> Decoder (Seq a)
sequence (Decoder extractIn expectedIn) = Decoder extractOut expectedOut
  where
    extractOut (ListLit _ es) = traverse extractIn es
    extractOut expr           = typeError expectedOut expr

    expectedOut = App List <$> expectedIn

{-| Decode a list

>>> input (list natural) "[1, 2, 3]"
[1,2,3]
-}
list :: Decoder a -> Decoder [a]
list = fmap Data.Foldable.toList . sequence

{-| Decode a `Vector`

>>> input (vector natural) "[1, 2, 3]"
[1,2,3]
-}
vector :: Decoder a -> Decoder (Vector a)
vector = fmap Data.Vector.fromList . list

{-| Decode a Dhall function into a Haskell function

>>> f <- input (function inject bool) "Natural/even" :: IO (Natural -> Bool)
>>> f 0
True
>>> f 1
False
-}
function
    :: Encoder a
    -> Decoder b
    -> Decoder (a -> b)
function = functionWith defaultInputNormalizer

{-| Decode a Dhall function into a Haskell function using the specified normalizer

>>> f <- input (functionWith defaultInputNormalizer inject bool) "Natural/even" :: IO (Natural -> Bool)
>>> f 0
True
>>> f 1
False
-}
functionWith
    :: InputNormalizer
    -> Encoder a
    -> Decoder b
    -> Decoder (a -> b)
functionWith inputNormalizer (Encoder {..}) (Decoder extractIn expectedIn) =
    Decoder extractOut expectedOut
  where
    normalizer_ = Just (getInputNormalizer inputNormalizer)

    extractOut e = pure (\i -> case extractIn (Dhall.Core.normalizeWith normalizer_ (App e (embed i))) of
        Success o  -> o
        Failure _e -> error "FromDhall: You cannot decode a function if it does not have the correct type" )

    expectedOut = Pi "_" declared <$> expectedIn

{-| Decode a `Set` from a `List`

>>> input (setIgnoringDuplicates natural) "[1, 2, 3]"
fromList [1,2,3]

Duplicate elements are ignored.

>>> input (setIgnoringDuplicates natural) "[1, 1, 3]"
fromList [1,3]

-}
setIgnoringDuplicates :: (Ord a) => Decoder a -> Decoder (Data.Set.Set a)
setIgnoringDuplicates = fmap Data.Set.fromList . list

{-| Decode a `HashSet` from a `List`

>>> input (hashSetIgnoringDuplicates natural) "[1, 2, 3]"
fromList [1,2,3]

Duplicate elements are ignored.

>>> input (hashSetIgnoringDuplicates natural) "[1, 1, 3]"
fromList [1,3]

-}
hashSetIgnoringDuplicates :: (Hashable a, Ord a)
                          => Decoder a
                          -> Decoder (Data.HashSet.HashSet a)
hashSetIgnoringDuplicates = fmap Data.HashSet.fromList . list

{-| Decode a `Set` from a `List` with distinct elements

>>> input (setFromDistinctList natural) "[1, 2, 3]"
fromList [1,2,3]

An error is thrown if the list contains duplicates.

> >>> input (setFromDistinctList natural) "[1, 1, 3]"
> *** Exception: Error: Failed extraction
>
> The expression type-checked successfully but the transformation to the target
> type failed with the following error:
>
> One duplicate element in the list: 1
>

> >>> input (setFromDistinctList natural) "[1, 1, 3, 3]"
> *** Exception: Error: Failed extraction
>
> The expression type-checked successfully but the transformation to the target
> type failed with the following error:
>
> 2 duplicates were found in the list, including 1
>

-}
setFromDistinctList :: (Ord a, Show a) => Decoder a -> Decoder (Data.Set.Set a)
setFromDistinctList = setHelper Data.Set.size Data.Set.fromList

{-| Decode a `HashSet` from a `List` with distinct elements

>>> input (hashSetFromDistinctList natural) "[1, 2, 3]"
fromList [1,2,3]

An error is thrown if the list contains duplicates.

> >>> input (hashSetFromDistinctList natural) "[1, 1, 3]"
> *** Exception: Error: Failed extraction
>
> The expression type-checked successfully but the transformation to the target
> type failed with the following error:
>
> One duplicate element in the list: 1
>

> >>> input (hashSetFromDistinctList natural) "[1, 1, 3, 3]"
> *** Exception: Error: Failed extraction
>
> The expression type-checked successfully but the transformation to the target
> type failed with the following error:
>
> 2 duplicates were found in the list, including 1
>

-}
hashSetFromDistinctList :: (Hashable a, Ord a, Show a)
                        => Decoder a
                        -> Decoder (Data.HashSet.HashSet a)
hashSetFromDistinctList = setHelper Data.HashSet.size Data.HashSet.fromList


setHelper :: (Eq a, Foldable t, Show a)
          => (t a -> Int)
          -> ([a] -> t a)
          -> Decoder a
          -> Decoder (t a)
setHelper size toSet (Decoder extractIn expectedIn) = Decoder extractOut expectedOut
  where
    extractOut (ListLit _ es) = case traverse extractIn es of
        Success vSeq
            | sameSize               -> Success vSet
            | otherwise              -> extractError err
          where
            vList = Data.Foldable.toList vSeq
            vSet = toSet vList
            sameSize = size vSet == Data.Sequence.length vSeq
            duplicates = vList Data.List.\\ Data.Foldable.toList vSet
            err | length duplicates == 1 =
                     "One duplicate element in the list: "
                     <> (Data.Text.pack $ show $ head duplicates)
                | otherwise              = Data.Text.pack $ unwords
                     [ show $ length duplicates
                     , "duplicates were found in the list, including"
                     , show $ head duplicates
                     ]
        Failure f -> Failure f
    extractOut expr = typeError expectedOut expr

    expectedOut = App List <$> expectedIn

{-| Decode a `Map` from a @toMap@ expression or generally a @Prelude.Map.Type@

>>> input (Dhall.map strictText bool) "toMap { a = True, b = False }"
fromList [("a",True),("b",False)]
>>> input (Dhall.map strictText bool) "[ { mapKey = \"foo\", mapValue = True } ]"
fromList [("foo",True)]

If there are duplicate @mapKey@s, later @mapValue@s take precedence:

>>> let expr = "[ { mapKey = 1, mapValue = True }, { mapKey = 1, mapValue = False } ]"
>>> input (Dhall.map natural bool) expr
fromList [(1,False)]

-}
map :: Ord k => Decoder k -> Decoder v -> Decoder (Map k v)
map k v = fmap Data.Map.fromList (list (pairFromMapEntry k v))

{-| Decode a `HashMap` from a @toMap@ expression or generally a @Prelude.Map.Type@

>>> input (Dhall.hashMap strictText bool) "toMap { a = True, b = False }"
fromList [("a",True),("b",False)]
>>> input (Dhall.hashMap strictText bool) "[ { mapKey = \"foo\", mapValue = True } ]"
fromList [("foo",True)]

If there are duplicate @mapKey@s, later @mapValue@s take precedence:

>>> let expr = "[ { mapKey = 1, mapValue = True }, { mapKey = 1, mapValue = False } ]"
>>> input (Dhall.hashMap natural bool) expr
fromList [(1,False)]

-}
hashMap :: (Eq k, Hashable k) => Decoder k -> Decoder v -> Decoder (HashMap k v)
hashMap k v = fmap HashMap.fromList (list (pairFromMapEntry k v))

{-| Decode a tuple from a @Prelude.Map.Entry@ record

>>> input (pairFromMapEntry strictText natural) "{ mapKey = \"foo\", mapValue = 3 }"
("foo",3)
-}
pairFromMapEntry :: Decoder k -> Decoder v -> Decoder (k, v)
pairFromMapEntry k v = Decoder extractOut expectedOut
  where
    extractOut (RecordLit kvs)
        | Just key <- Dhall.Core.recordFieldValue <$> Dhall.Map.lookup "mapKey" kvs
        , Just value <- Dhall.Core.recordFieldValue <$> Dhall.Map.lookup "mapValue" kvs
            = liftA2 (,) (extract k key) (extract v value)
    extractOut expr = typeError expectedOut expr

    expectedOut = do
        k' <- expected k
        v' <- expected v
        pure $ Record $ Dhall.Core.makeRecordField <$> Dhall.Map.fromList
            [ ("mapKey", k')
            , ("mapValue", v')]

{-| Decode @()@ from an empty record.

>>> input unit "{=}"  -- GHC doesn't print the result if it is ()

-}
unit :: Decoder ()
unit = Decoder {..}
  where
    extract (RecordLit fields)
        | Data.Foldable.null fields = pure ()
    extract expr = typeError expected expr

    expected = pure $ Record mempty

{-| Decode 'Void' from an empty union.

Since @<>@ is uninhabited, @'input' 'void'@ will always fail.
-}
void :: Decoder Void
void = union mempty

{-| Decode a `String`

>>> input string "\"ABC\""
"ABC"

-}
string :: Decoder String
string = Data.Text.Lazy.unpack <$> lazyText

{-| Given a pair of `Decoder`s, decode a tuple-record into their pairing.

>>> input (pair natural bool) "{ _1 = 42, _2 = False }"
(42,False)
-}
pair :: Decoder a -> Decoder b -> Decoder (a, b)
pair l r = Decoder extractOut expectedOut
  where
    extractOut expr@(RecordLit fields) =
      (,) <$> Data.Maybe.maybe (typeError expectedOut expr) (extract l)
                (Dhall.Core.recordFieldValue <$> Dhall.Map.lookup "_1" fields)
          <*> Data.Maybe.maybe (typeError expectedOut expr) (extract r)
                (Dhall.Core.recordFieldValue <$> Dhall.Map.lookup "_2" fields)
    extractOut expr = typeError expectedOut expr

    expectedOut = do
        l' <- expected l
        r' <- expected r
        pure $ Record $ Dhall.Core.makeRecordField <$> Dhall.Map.fromList
            [ ("_1", l')
            , ("_2", r')]

{-| Any value that implements `FromDhall` can be automatically decoded based on
    the inferred return type of `input`

>>> input auto "[1, 2, 3]" :: IO (Vector Natural)
[1,2,3]
>>> input auto "toMap { a = False, b = True }" :: IO (Map Text Bool)
fromList [("a",False),("b",True)]

    This class auto-generates a default implementation for types that
    implement `Generic`.  This does not auto-generate an instance for recursive
    types.

    The default instance can be tweaked using 'genericAutoWith' and custom
    'InterpretOptions', or using
    [DerivingVia](https://downloads.haskell.org/~ghc/latest/docs/html/users_guide/glasgow_exts.html#extension-DerivingVia)
    and 'Dhall.Deriving.Codec' from "Dhall.Deriving".
-}
class FromDhall a where
    autoWith :: InputNormalizer -> Decoder a
    default autoWith
        :: (Generic a, GenericFromDhall a (Rep a)) => InputNormalizer -> Decoder a
    autoWith _ = genericAuto

{-| A compatibility alias for `FromDhall`

This will eventually be removed.
-}
type Interpret = FromDhall

instance FromDhall Void where
    autoWith _ = void

instance FromDhall () where
    autoWith _ = unit

instance FromDhall Bool where
    autoWith _ = bool

instance FromDhall Natural where
    autoWith _ = natural

instance FromDhall Integer where
    autoWith _ = integer

instance FromDhall Scientific where
    autoWith _ = scientific

instance FromDhall Double where
    autoWith _ = double

instance {-# OVERLAPS #-} FromDhall [Char] where
    autoWith _ = string

instance FromDhall Data.Text.Lazy.Text where
    autoWith _ = lazyText

instance FromDhall Text where
    autoWith _ = strictText

instance FromDhall a => FromDhall (Maybe a) where
    autoWith opts = maybe (autoWith opts)

instance FromDhall a => FromDhall (Seq a) where
    autoWith opts = sequence (autoWith opts)

instance FromDhall a => FromDhall [a] where
    autoWith opts = list (autoWith opts)

instance FromDhall a => FromDhall (Vector a) where
    autoWith opts = vector (autoWith opts)

{-| Note that this instance will throw errors in the presence of duplicates in
    the list. To ignore duplicates, use `setIgnoringDuplicates`.
-}
instance (FromDhall a, Ord a, Show a) => FromDhall (Data.Set.Set a) where
    autoWith opts = setFromDistinctList (autoWith opts)

{-| Note that this instance will throw errors in the presence of duplicates in
    the list. To ignore duplicates, use `hashSetIgnoringDuplicates`.
-}
instance (FromDhall a, Hashable a, Ord a, Show a) => FromDhall (Data.HashSet.HashSet a) where
    autoWith inputNormalizer = hashSetFromDistinctList (autoWith inputNormalizer)

instance (Ord k, FromDhall k, FromDhall v) => FromDhall (Map k v) where
    autoWith inputNormalizer = Dhall.map (autoWith inputNormalizer) (autoWith inputNormalizer)

instance (Eq k, Hashable k, FromDhall k, FromDhall v) => FromDhall (HashMap k v) where
    autoWith inputNormalizer = Dhall.hashMap (autoWith inputNormalizer) (autoWith inputNormalizer)

instance (ToDhall a, FromDhall b) => FromDhall (a -> b) where
    autoWith inputNormalizer =
        functionWith inputNormalizer (injectWith inputNormalizer) (autoWith inputNormalizer)

instance (FromDhall a, FromDhall b) => FromDhall (a, b)

{-| Use the default input normalizer for interpreting a configuration file

> auto = autoWith defaultInputNormalizer
-}
auto :: FromDhall a => Decoder a
auto = autoWith defaultInputNormalizer

{-| This type is exactly the same as `Data.Fix.Fix` except with a different
    `FromDhall` instance.  This intermediate type simplifies the implementation
    of the inner loop for the `FromDhall` instance for `Fix`
-}
newtype Result f = Result { _unResult :: f (Result f) }

resultToFix :: Functor f => Result f -> Fix f
resultToFix (Result x) = Fix (fmap resultToFix x)

instance FromDhall (f (Result f)) => FromDhall (Result f) where
    autoWith inputNormalizer = Decoder {..}
      where
        extract (App _ expr) =
            fmap Result (Dhall.extract (autoWith inputNormalizer) expr)
        extract expr = typeError expected expr

        expected = pure "result"

-- | You can use this instance to marshal recursive types from Dhall to Haskell.
--
-- Here is an example use of this instance:
--
-- > {-# LANGUAGE DeriveAnyClass     #-}
-- > {-# LANGUAGE DeriveFoldable     #-}
-- > {-# LANGUAGE DeriveFunctor      #-}
-- > {-# LANGUAGE DeriveTraversable  #-}
-- > {-# LANGUAGE DeriveGeneric      #-}
-- > {-# LANGUAGE KindSignatures     #-}
-- > {-# LANGUAGE QuasiQuotes        #-}
-- > {-# LANGUAGE StandaloneDeriving #-}
-- > {-# LANGUAGE TypeFamilies       #-}
-- > {-# LANGUAGE TemplateHaskell    #-}
-- >
-- > import Data.Fix (Fix(..))
-- > import Data.Text (Text)
-- > import Dhall (FromDhall)
-- > import GHC.Generics (Generic)
-- > import Numeric.Natural (Natural)
-- >
-- > import qualified Data.Fix                 as Fix
-- > import qualified Data.Functor.Foldable    as Foldable
-- > import qualified Data.Functor.Foldable.TH as TH
-- > import qualified Dhall
-- > import qualified NeatInterpolation
-- >
-- > data Expr
-- >     = Lit Natural
-- >     | Add Expr Expr
-- >     | Mul Expr Expr
-- >     deriving (Show)
-- >
-- > TH.makeBaseFunctor ''Expr
-- >
-- > deriving instance Generic (ExprF a)
-- > deriving instance FromDhall a => FromDhall (ExprF a)
-- >
-- > example :: Text
-- > example = [NeatInterpolation.text|
-- >     \(Expr : Type)
-- > ->  let ExprF =
-- >           < LitF :
-- >               Natural
-- >           | AddF :
-- >               { _1 : Expr, _2 : Expr }
-- >           | MulF :
-- >               { _1 : Expr, _2 : Expr }
-- >           >
-- >
-- >     in      \(Fix : ExprF -> Expr)
-- >         ->  let Lit = \(x : Natural) -> Fix (ExprF.LitF x)
-- >
-- >             let Add =
-- >                       \(x : Expr)
-- >                   ->  \(y : Expr)
-- >                   ->  Fix (ExprF.AddF { _1 = x, _2 = y })
-- >
-- >             let Mul =
-- >                       \(x : Expr)
-- >                   ->  \(y : Expr)
-- >                   ->  Fix (ExprF.MulF { _1 = x, _2 = y })
-- >
-- >             in  Add (Mul (Lit 3) (Lit 7)) (Add (Lit 1) (Lit 2))
-- > |]
-- >
-- > convert :: Fix ExprF -> Expr
-- > convert = Fix.cata Foldable.embed
-- >
-- > main :: IO ()
-- > main = do
-- >     x <- Dhall.input Dhall.auto example :: IO (Fix ExprF)
-- >
-- >     print (convert x :: Expr)
instance (Functor f, FromDhall (f (Result f))) => FromDhall (Fix f) where
    autoWith inputNormalizer = Decoder {..}
      where
        extract expr0 = extract0 expr0
          where
            die = typeError expected expr0

            extract0 (Lam x _ expr) = extract1 (rename x "result" expr)
            extract0  _             = die

            extract1 (Lam y _ expr) = extract2 (rename y "Make" expr)
            extract1  _             = die

            extract2 expr = fmap resultToFix (Dhall.extract (autoWith inputNormalizer) expr)

            rename a b expr
                | a /= b    = Dhall.Core.subst (V a 0) (Var (V b 0)) (Dhall.Core.shift 1 (V b 0) expr)
                | otherwise = expr

        expected = (\x -> Pi "result" (Const Dhall.Core.Type) (Pi "Make" (Pi "_" x "result") "result"))
            <$> Dhall.expected (autoWith inputNormalizer :: Decoder (f (Result f)))

{-| `genericAuto` is the default implementation for `auto` if you derive
    `FromDhall`.  The difference is that you can use `genericAuto` without
    having to explicitly provide a `FromDhall` instance for a type as long as
    the type derives `Generic`
-}
genericAuto :: (Generic a, GenericFromDhall a (Rep a)) => Decoder a
genericAuto = genericAutoWith defaultInterpretOptions

{-| `genericAutoWith` is a configurable version of `genericAuto`.
-}
genericAutoWith :: (Generic a, GenericFromDhall a (Rep a)) => InterpretOptions -> Decoder a
genericAutoWith options = withProxy (\p -> fmap to (evalState (genericAutoWithNormalizer p defaultInputNormalizer options) 1))
    where
        withProxy :: (Proxy a -> Decoder a) -> Decoder a
        withProxy f = f Proxy


{-| Use these options to tweak how Dhall derives a generic implementation of
    `FromDhall`
-}
data InterpretOptions = InterpretOptions
    { fieldModifier       :: Text -> Text
    -- ^ Function used to transform Haskell field names into their corresponding
    --   Dhall field names
    , constructorModifier :: Text -> Text
    -- ^ Function used to transform Haskell constructor names into their
    --   corresponding Dhall alternative names
    , singletonConstructors :: SingletonConstructors
    -- ^ Specify how to handle constructors with only one field.  The default is
    --   `Smart`
    }

-- | This is only used by the `FromDhall` instance for functions in order
--   to normalize the function input before marshaling the input into a
--   Dhall expression
newtype InputNormalizer = InputNormalizer
  { getInputNormalizer :: Dhall.Core.ReifiedNormalizer Void }

-- | Default normalization-related settings (no custom normalization)
defaultInputNormalizer :: InputNormalizer
defaultInputNormalizer = InputNormalizer
 { getInputNormalizer = Dhall.Core.ReifiedNormalizer (const (pure Nothing)) }

{-| This type specifies how to model a Haskell constructor with 1 field in
    Dhall

    For example, consider the following Haskell datatype definition:

    > data Example = Foo { x :: Double } | Bar Double

    Depending on which option you pick, the corresponding Dhall type could be:

    > < Foo : Double | Bar : Double >                   -- Bare

    > < Foo : { x : Double } | Bar : { _1 : Double } >  -- Wrapped

    > < Foo : { x : Double } | Bar : Double >           -- Smart
-}
data SingletonConstructors
    = Bare
    -- ^ Never wrap the field in a record
    | Wrapped
    -- ^ Always wrap the field in a record
    | Smart
    -- ^ Only fields in a record if they are named

{-| Default interpret options for generics-based instances,
    which you can tweak or override, like this:

> genericAutoWith
>     (defaultInterpretOptions { fieldModifier = Data.Text.Lazy.dropWhile (== '_') })
-}
defaultInterpretOptions :: InterpretOptions
defaultInterpretOptions = InterpretOptions
    { fieldModifier =
          id
    , constructorModifier =
          id
    , singletonConstructors =
          Smart
    }

{-| This is the underlying class that powers the `FromDhall` class's support
    for automatically deriving a generic implementation
-}
class GenericFromDhall t f where
    genericAutoWithNormalizer :: Proxy t -> InputNormalizer -> InterpretOptions -> State Int (Decoder (f a))

instance GenericFromDhall t f => GenericFromDhall t (M1 D d f) where
    genericAutoWithNormalizer p inputNormalizer options = do
        res <- genericAutoWithNormalizer p inputNormalizer options
        pure (fmap M1 res)

instance GenericFromDhall t V1 where
    genericAutoWithNormalizer _ _ _ = pure Decoder {..}
      where
        extract expr = typeError expected expr

        expected = pure $ Union mempty

unsafeExpectUnion
    :: Text -> Expr Src Void -> Dhall.Map.Map Text (Maybe (Expr Src Void))
unsafeExpectUnion _ (Union kts) =
    kts
unsafeExpectUnion name expression =
    Dhall.Core.internalError
        (name <> ": Unexpected constructor: " <> Dhall.Core.pretty expression)

unsafeExpectRecord
    :: Text -> Expr Src Void -> Dhall.Map.Map Text (RecordField Src Void)
unsafeExpectRecord _ (Record kts) =
    kts
unsafeExpectRecord name expression =
    Dhall.Core.internalError
        (name <> ": Unexpected constructor: " <> Dhall.Core.pretty expression)

unsafeExpectUnionLit
    :: Text
    -> Expr Src Void
    -> (Text, Maybe (Expr Src Void))
unsafeExpectUnionLit _ (Field (Union _) k) =
    (k, Nothing)
unsafeExpectUnionLit _ (App (Field (Union _) k) v) =
    (k, Just v)
unsafeExpectUnionLit name expression =
    Dhall.Core.internalError
        (name <> ": Unexpected constructor: " <> Dhall.Core.pretty expression)

unsafeExpectRecordLit
    :: Text -> Expr Src Void -> Dhall.Map.Map Text (RecordField Src Void)
unsafeExpectRecordLit _ (RecordLit kvs) =
    kvs
unsafeExpectRecordLit name expression =
    Dhall.Core.internalError
        (name <> ": Unexpected constructor: " <> Dhall.Core.pretty expression)

notEmptyRecordLit :: Expr s a -> Maybe (Expr s a)
notEmptyRecordLit e = case e of
    RecordLit m | null m -> Nothing
    _                    -> Just e

notEmptyRecord :: Expr s a -> Maybe (Expr s a)
notEmptyRecord e = case e of
    Record m | null m -> Nothing
    _                 -> Just e
extractUnionConstructor
    :: Expr s a -> Maybe (Text, Expr s a, Dhall.Map.Map Text (Maybe (Expr s a)))
extractUnionConstructor (App (Field (Union kts) fld) e) =
  return (fld, e, Dhall.Map.delete fld kts)
extractUnionConstructor (Field (Union kts) fld) =
  return (fld, RecordLit mempty, Dhall.Map.delete fld kts)
extractUnionConstructor _ =
  empty

class GenericFromDhallUnion t f where
    genericUnionAutoWithNormalizer :: Proxy t -> InputNormalizer -> InterpretOptions -> UnionDecoder (f a)

instance (GenericFromDhallUnion t f1, GenericFromDhallUnion t f2) => GenericFromDhallUnion t (f1 :+: f2) where
  genericUnionAutoWithNormalizer p inputNormalizer options =
    (<>)
      (L1 <$> genericUnionAutoWithNormalizer p inputNormalizer options)
      (R1 <$> genericUnionAutoWithNormalizer p inputNormalizer options)

instance (Constructor c1, GenericFromDhall t f1) => GenericFromDhallUnion t (M1 C c1 f1) where
  genericUnionAutoWithNormalizer p inputNormalizer options@(InterpretOptions {..}) =
    constructor name (evalState (genericAutoWithNormalizer p inputNormalizer options) 1)
    where
      n :: M1 C c1 f1 a
      n = undefined

      name = constructorModifier (Data.Text.pack (conName n))

instance GenericFromDhallUnion t (f :+: g) => GenericFromDhall t (f :+: g) where
  genericAutoWithNormalizer p inputNormalizer options =
    pure (union (genericUnionAutoWithNormalizer p inputNormalizer options))

instance GenericFromDhall t f => GenericFromDhall t (M1 C c f) where
    genericAutoWithNormalizer p inputNormalizer options = do
        res <- genericAutoWithNormalizer p inputNormalizer options
        pure (fmap M1 res)

instance GenericFromDhall t U1 where
    genericAutoWithNormalizer _ _ _ = pure (Decoder {..})
      where
        extract _ = pure U1

        expected = pure expected'

        expected' = Record (Dhall.Map.fromList [])

getSelName :: Selector s => M1 i s f a -> State Int Text
getSelName n = case selName n of
    "" -> do i <- get
             put (i + 1)
             pure (Data.Text.pack ("_" ++ show i))
    nn -> pure (Data.Text.pack nn)

instance (GenericFromDhall t (f :*: g), GenericFromDhall t (h :*: i)) => GenericFromDhall t ((f :*: g) :*: (h :*: i)) where
    genericAutoWithNormalizer p inputNormalizer options = do
        Decoder extractL expectedL <- genericAutoWithNormalizer p inputNormalizer options
        Decoder extractR expectedR <- genericAutoWithNormalizer p inputNormalizer options

        let ktsL = unsafeExpectRecord "genericAutoWithNormalizer (:*:)" <$> expectedL
        let ktsR = unsafeExpectRecord "genericAutoWithNormalizer (:*:)" <$> expectedR

        let expected = Record <$> (Dhall.Map.union <$> ktsL <*> ktsR)

        let extract expression =
                liftA2 (:*:) (extractL expression) (extractR expression)

        return (Decoder {..})

instance (GenericFromDhall t (f :*: g), Selector s, FromDhall a) => GenericFromDhall t ((f :*: g) :*: M1 S s (K1 i a)) where
    genericAutoWithNormalizer p inputNormalizer options@InterpretOptions{..} = do
        let nR :: M1 S s (K1 i a) r
            nR = undefined

        nameR <- fmap fieldModifier (getSelName nR)

        Decoder extractL expectedL <- genericAutoWithNormalizer p inputNormalizer options

        let Decoder extractR expectedR = autoWith inputNormalizer

        let ktsL = unsafeExpectRecord "genericAutoWithNormalizer (:*:)" <$> expectedL

        let expected = Record <$> (Dhall.Map.insert nameR . Dhall.Core.makeRecordField <$> expectedR <*> ktsL)

        let extract expression = do
                let die = typeError expected expression

                case expression of
                    RecordLit kvs ->
                        case Dhall.Core.recordFieldValue <$> Dhall.Map.lookup nameR kvs of
                            Just expressionR ->
                                liftA2 (:*:)
                                    (extractL expression)
                                    (fmap (M1 . K1) (extractR expressionR))
                            _ -> die
                    _ -> die

        return (Decoder {..})

instance (Selector s, FromDhall a, GenericFromDhall t (f :*: g)) => GenericFromDhall t (M1 S s (K1 i a) :*: (f :*: g)) where
    genericAutoWithNormalizer p inputNormalizer options@InterpretOptions{..} = do
        let nL :: M1 S s (K1 i a) r
            nL = undefined

        nameL <- fmap fieldModifier (getSelName nL)

        let Decoder extractL expectedL = autoWith inputNormalizer

        Decoder extractR expectedR <- genericAutoWithNormalizer p inputNormalizer options

        let ktsR = unsafeExpectRecord "genericAutoWithNormalizer (:*:)" <$> expectedR

        let expected = Record <$> (Dhall.Map.insert nameL . Dhall.Core.makeRecordField <$> expectedL <*> ktsR)

        let extract expression = do
                let die = typeError expected expression

                case expression of
                    RecordLit kvs ->
                        case Dhall.Core.recordFieldValue <$> Dhall.Map.lookup nameL kvs of
                            Just expressionL ->
                                liftA2 (:*:)
                                    (fmap (M1 . K1) (extractL expressionL))
                                    (extractR expression)
                            _ -> die
                    _ -> die

        return (Decoder {..})

instance {-# OVERLAPPING #-} GenericFromDhall a1 (M1 S s1 (K1 i1 a1) :*: M1 S s2 (K1 i2 a2)) where
    genericAutoWithNormalizer _ _ _ = pure $ Decoder
        { extract = \_ -> Failure $ DhallErrors $ pure $ ExpectedTypeError RecursiveTypeError
        , expected = Failure $ DhallErrors $ pure RecursiveTypeError
        }

instance {-# OVERLAPPING #-} GenericFromDhall a2 (M1 S s1 (K1 i1 a1) :*: M1 S s2 (K1 i2 a2)) where
    genericAutoWithNormalizer _ _ _ = pure $ Decoder
        { extract = \_ -> Failure $ DhallErrors $ pure $ ExpectedTypeError RecursiveTypeError
        , expected = Failure $ DhallErrors $ pure RecursiveTypeError
        }

instance {-# OVERLAPPABLE #-} (Selector s1, Selector s2, FromDhall a1, FromDhall a2) => GenericFromDhall t (M1 S s1 (K1 i1 a1) :*: M1 S s2 (K1 i2 a2)) where
    genericAutoWithNormalizer _ inputNormalizer InterpretOptions{..} = do
        let nL :: M1 S s1 (K1 i1 a1) r
            nL = undefined

        let nR :: M1 S s2 (K1 i2 a2) r
            nR = undefined

        nameL <- fmap fieldModifier (getSelName nL)
        nameR <- fmap fieldModifier (getSelName nR)

        let Decoder extractL expectedL = autoWith inputNormalizer
        let Decoder extractR expectedR = autoWith inputNormalizer

        let expected = do
                l <- Dhall.Core.makeRecordField <$> expectedL
                r <- Dhall.Core.makeRecordField <$> expectedR
                pure $ Record
                    (Dhall.Map.fromList
                        [ (nameL, l)
                        , (nameR, r)
                        ]
                    )

        let extract expression = do
                let die = typeError expected expression

                case expression of
                    RecordLit kvs ->
                        case liftA2 (,) (Dhall.Map.lookup nameL kvs) (Dhall.Map.lookup nameR kvs) of
                            Just (expressionL, expressionR) ->
                                liftA2 (:*:)
                                    (fmap (M1 . K1) (extractL $ Dhall.Core.recordFieldValue expressionL))
                                    (fmap (M1 . K1) (extractR $ Dhall.Core.recordFieldValue expressionR))
                            Nothing -> die
                    _ -> die

        return (Decoder {..})

instance {-# OVERLAPPING #-} GenericFromDhall a (M1 S s (K1 i a)) where
    genericAutoWithNormalizer _ _ _ = pure $ Decoder
        { extract = \_ -> Failure $ DhallErrors $ pure $ ExpectedTypeError RecursiveTypeError
        , expected = Failure $ DhallErrors $ pure RecursiveTypeError
        }

instance {-# OVERLAPPABLE #-} (Selector s, FromDhall a) => GenericFromDhall t (M1 S s (K1 i a)) where
    genericAutoWithNormalizer _ inputNormalizer InterpretOptions{..} = do
        let n :: M1 S s (K1 i a) r
            n = undefined

        name <- fmap fieldModifier (getSelName n)

        let Decoder { extract = extract', expected = expected'} = autoWith inputNormalizer

        let expected =
                case singletonConstructors of
                    Bare ->
                        expected'
                    Smart | selName n == "" ->
                        expected'
                    _ ->
                        Record . Dhall.Map.singleton name . Dhall.Core.makeRecordField <$> expected'

        let extract0 expression = fmap (M1 . K1) (extract' expression)

        let extract1 expression = do
                let die = typeError expected expression

                case expression of
                    RecordLit kvs ->
                        case Dhall.Core.recordFieldValue <$> Dhall.Map.lookup name kvs of
                            Just subExpression ->
                                fmap (M1 . K1) (extract' subExpression)
                            Nothing ->
                                die
                    _ -> die

        let extract =
                case singletonConstructors of
                    Bare                    -> extract0
                    Smart | selName n == "" -> extract0
                    _                       -> extract1

        return (Decoder {..})

{-| An @(Encoder a)@ represents a way to marshal a value of type @\'a\'@ from
    Haskell into Dhall
-}
data Encoder a = Encoder
    { embed    :: a -> Expr Src Void
    -- ^ Embeds a Haskell value as a Dhall expression
    , declared :: Expr Src Void
    -- ^ Dhall type of the Haskell value
    }

instance Contravariant Encoder where
    contramap f (Encoder embed declared) = Encoder embed' declared
      where
        embed' x = embed (f x)

{-| This class is used by `FromDhall` instance for functions:

> instance (ToDhall a, FromDhall b) => FromDhall (a -> b)

    You can convert Dhall functions with "simple" inputs (i.e. instances of this
    class) into Haskell functions.  This works by:

    * Marshaling the input to the Haskell function into a Dhall expression (i.e.
      @x :: Expr Src Void@)
    * Applying the Dhall function (i.e. @f :: Expr Src Void@) to the Dhall input
      (i.e. @App f x@)
    * Normalizing the syntax tree (i.e. @normalize (App f x)@)
    * Marshaling the resulting Dhall expression back into a Haskell value

    This class auto-generates a default implementation for types that
    implement `Generic`.  This does not auto-generate an instance for recursive
    types.

    The default instance can be tweaked using 'genericToDhallWith' and custom
    'InterpretOptions', or using
    [DerivingVia](https://downloads.haskell.org/~ghc/latest/docs/html/users_guide/glasgow_exts.html#extension-DerivingVia)
    and 'Dhall.Deriving.Codec' from "Dhall.Deriving".
-}
class ToDhall a where
    injectWith :: InputNormalizer -> Encoder a
    default injectWith
        :: (Generic a, GenericToDhall (Rep a)) => InputNormalizer -> Encoder a
    injectWith _ = genericToDhall

{-| A compatibility alias for `ToDhall`

This will eventually be removed.
-}
type Inject = ToDhall

{-| Use the default input normalizer for injecting a value

> inject = injectWith defaultInputNormalizer
-}
inject :: ToDhall a => Encoder a
inject = injectWith defaultInputNormalizer

{-| Use the default options for injecting a value, whose structure is
determined generically.

This can be used when you want to use 'ToDhall' on types that you don't
want to define orphan instances for.
-}
genericToDhall
  :: (Generic a, GenericToDhall (Rep a)) => Encoder a
genericToDhall
    = genericToDhallWith defaultInterpretOptions

{-| Use custom options for injecting a value, whose structure is
determined generically.

This can be used when you want to use 'ToDhall' on types that you don't
want to define orphan instances for.
-}
genericToDhallWith
  :: (Generic a, GenericToDhall (Rep a)) => InterpretOptions -> Encoder a
genericToDhallWith options
    = contramap GHC.Generics.from (evalState (genericToDhallWithNormalizer defaultInputNormalizer options) 1)

instance ToDhall Void where
    injectWith _ = Encoder {..}
      where
        embed = Data.Void.absurd

        declared = Union mempty

instance ToDhall Bool where
    injectWith _ = Encoder {..}
      where
        embed = BoolLit

        declared = Bool

instance ToDhall Data.Text.Lazy.Text where
    injectWith _ = Encoder {..}
      where
        embed text =
            TextLit (Chunks [] (Data.Text.Lazy.toStrict text))

        declared = Text

instance ToDhall Text where
    injectWith _ = Encoder {..}
      where
        embed text = TextLit (Chunks [] text)

        declared = Text

instance {-# OVERLAPS #-} ToDhall String where
    injectWith inputNormalizer =
        contramap Data.Text.pack (injectWith inputNormalizer :: Encoder Text)

instance ToDhall Natural where
    injectWith _ = Encoder {..}
      where
        embed = NaturalLit

        declared = Natural

instance ToDhall Integer where
    injectWith _ = Encoder {..}
      where
        embed = IntegerLit

        declared = Integer

instance ToDhall Int where
    injectWith _ = Encoder {..}
      where
        embed = IntegerLit . toInteger

        declared = Integer

{-|

>>> embed inject (12 :: Word)
NaturalLit 12
-}

instance ToDhall Word where
    injectWith _ = Encoder {..}
      where
        embed = NaturalLit . fromIntegral

        declared = Natural

{-|

>>> embed inject (12 :: Word8)
NaturalLit 12
-}

instance ToDhall Word8 where
    injectWith _ = Encoder {..}
      where
        embed = NaturalLit . fromIntegral

        declared = Natural

{-|

>>> embed inject (12 :: Word16)
NaturalLit 12
-}

instance ToDhall Word16 where
    injectWith _ = Encoder {..}
      where
        embed = NaturalLit . fromIntegral

        declared = Natural

{-|

>>> embed inject (12 :: Word32)
NaturalLit 12
-}

instance ToDhall Word32 where
    injectWith _ = Encoder {..}
      where
        embed = NaturalLit . fromIntegral

        declared = Natural

{-|

>>> embed inject (12 :: Word64)
NaturalLit 12
-}

instance ToDhall Word64 where
    injectWith _ = Encoder {..}
      where
        embed = NaturalLit . fromIntegral

        declared = Natural

instance ToDhall Double where
    injectWith _ = Encoder {..}
      where
        embed = DoubleLit . DhallDouble

        declared = Double

instance ToDhall Scientific where
    injectWith inputNormalizer =
        contramap Data.Scientific.toRealFloat (injectWith inputNormalizer :: Encoder Double)

instance ToDhall () where
    injectWith _ = Encoder {..}
      where
        embed = const (RecordLit mempty)

        declared = Record mempty

instance ToDhall a => ToDhall (Maybe a) where
    injectWith inputNormalizer = Encoder embedOut declaredOut
      where
        embedOut (Just x ) = Some (embedIn x)
        embedOut  Nothing  = App None declaredIn

        Encoder embedIn declaredIn = injectWith inputNormalizer

        declaredOut = App Optional declaredIn

instance ToDhall a => ToDhall (Seq a) where
    injectWith inputNormalizer = Encoder embedOut declaredOut
      where
        embedOut xs = ListLit listType (fmap embedIn xs)
          where
            listType
                | null xs   = Just (App List declaredIn)
                | otherwise = Nothing

        declaredOut = App List declaredIn

        Encoder embedIn declaredIn = injectWith inputNormalizer

instance ToDhall a => ToDhall [a] where
    injectWith = fmap (contramap Data.Sequence.fromList) injectWith

instance ToDhall a => ToDhall (Vector a) where
    injectWith = fmap (contramap Data.Vector.toList) injectWith

{-| Note that the output list will be sorted

>>> let x = Data.Set.fromList ["mom", "hi" :: Text]
>>> prettyExpr $ embed inject x
[ "hi", "mom" ]

-}
instance ToDhall a => ToDhall (Data.Set.Set a) where
    injectWith = fmap (contramap Data.Set.toAscList) injectWith

{-| Note that the output list may not be sorted

>>> let x = Data.HashSet.fromList ["hi", "mom" :: Text]
>>> prettyExpr $ embed inject x
[ "mom", "hi" ]

-}
instance ToDhall a => ToDhall (Data.HashSet.HashSet a) where
    injectWith = fmap (contramap Data.HashSet.toList) injectWith

instance (ToDhall a, ToDhall b) => ToDhall (a, b)

{-| Embed a `Data.Map` as a @Prelude.Map.Type@

>>> prettyExpr $ embed inject (Data.Map.fromList [(1 :: Natural, True)])
[ { mapKey = 1, mapValue = True } ]

>>> prettyExpr $ embed inject (Data.Map.fromList [] :: Data.Map.Map Natural Bool)
[] : List { mapKey : Natural, mapValue : Bool }

-}
instance (ToDhall k, ToDhall v) => ToDhall (Data.Map.Map k v) where
    injectWith inputNormalizer = Encoder embedOut declaredOut
      where
        embedOut m = ListLit listType (mapEntries m)
          where
            listType
                | Data.Map.null m = Just declaredOut
                | otherwise       = Nothing

        declaredOut = App List (Record $ Dhall.Core.makeRecordField <$> Dhall.Map.fromList
                          [("mapKey", declaredK), ("mapValue", declaredV)])

        mapEntries = Data.Sequence.fromList . fmap recordPair . Data.Map.toList
        recordPair (k, v) = RecordLit $ Dhall.Core.makeRecordField <$> Dhall.Map.fromList
                                [("mapKey", embedK k), ("mapValue", embedV v)]

        Encoder embedK declaredK = injectWith inputNormalizer
        Encoder embedV declaredV = injectWith inputNormalizer

{-| Embed a `Data.HashMap` as a @Prelude.Map.Type@

>>> prettyExpr $ embed inject (HashMap.fromList [(1 :: Natural, True)])
[ { mapKey = 1, mapValue = True } ]

>>> prettyExpr $ embed inject (HashMap.fromList [] :: HashMap Natural Bool)
[] : List { mapKey : Natural, mapValue : Bool }

-}
instance (ToDhall k, ToDhall v) => ToDhall (HashMap k v) where
    injectWith inputNormalizer = Encoder embedOut declaredOut
      where
        embedOut m = ListLit listType (mapEntries m)
          where
            listType
                | HashMap.null m = Just declaredOut
                | otherwise       = Nothing

        declaredOut = App List (Record $ Dhall.Core.makeRecordField <$> Dhall.Map.fromList
                          [("mapKey", declaredK), ("mapValue", declaredV)])

        mapEntries = Data.Sequence.fromList . fmap recordPair . HashMap.toList
        recordPair (k, v) = RecordLit $ Dhall.Core.makeRecordField <$> Dhall.Map.fromList
                                [("mapKey", embedK k), ("mapValue", embedV v)]

        Encoder embedK declaredK = injectWith inputNormalizer
        Encoder embedV declaredV = injectWith inputNormalizer

{-| This is the underlying class that powers the `FromDhall` class's support
    for automatically deriving a generic implementation
-}
class GenericToDhall f where
    genericToDhallWithNormalizer :: InputNormalizer -> InterpretOptions -> State Int (Encoder (f a))

instance GenericToDhall f => GenericToDhall (M1 D d f) where
    genericToDhallWithNormalizer inputNormalizer options = do
        res <- genericToDhallWithNormalizer inputNormalizer options
        pure (contramap unM1 res)

instance GenericToDhall f => GenericToDhall (M1 C c f) where
    genericToDhallWithNormalizer inputNormalizer options = do
        res <- genericToDhallWithNormalizer inputNormalizer options
        pure (contramap unM1 res)

instance (Selector s, ToDhall a) => GenericToDhall (M1 S s (K1 i a)) where
    genericToDhallWithNormalizer inputNormalizer InterpretOptions{..} = do
        let Encoder { embed = embed', declared = declared' } =
                injectWith inputNormalizer

        let n :: M1 S s (K1 i a) r
            n = undefined

        name <- fieldModifier <$> getSelName n

        let embed0 (M1 (K1 x)) = embed' x

        let embed1 (M1 (K1 x)) =
                RecordLit (Dhall.Map.singleton name (Dhall.Core.makeRecordField $ embed' x))

        let embed =
                case singletonConstructors of
                    Bare                    -> embed0
                    Smart | selName n == "" -> embed0
                    _                       -> embed1

        let declared =
                case singletonConstructors of
                    Bare ->
                        declared'
                    Smart | selName n == "" ->
                        declared'
                    _ ->
                        Record (Dhall.Map.singleton name $ Dhall.Core.makeRecordField declared')

        return (Encoder {..})

instance (Constructor c1, Constructor c2, GenericToDhall f1, GenericToDhall f2) => GenericToDhall (M1 C c1 f1 :+: M1 C c2 f2) where
    genericToDhallWithNormalizer inputNormalizer options@(InterpretOptions {..}) = pure (Encoder {..})
      where
        embed (L1 (M1 l)) =
            case notEmptyRecordLit (embedL l) of
                Nothing ->
                    Field declared keyL
                Just valL ->
                    App (Field declared keyL) valL

        embed (R1 (M1 r)) =
            case notEmptyRecordLit (embedR r) of
                Nothing ->
                    Field declared keyR
                Just valR ->
                    App (Field declared keyR) valR

        declared =
            Union
                (Dhall.Map.fromList
                    [ (keyL, notEmptyRecord declaredL)
                    , (keyR, notEmptyRecord declaredR)
                    ]
                )

        nL :: M1 i c1 f1 a
        nL = undefined

        nR :: M1 i c2 f2 a
        nR = undefined

        keyL = constructorModifier (Data.Text.pack (conName nL))
        keyR = constructorModifier (Data.Text.pack (conName nR))

        Encoder embedL declaredL = evalState (genericToDhallWithNormalizer inputNormalizer options) 1
        Encoder embedR declaredR = evalState (genericToDhallWithNormalizer inputNormalizer options) 1

instance (Constructor c, GenericToDhall (f :+: g), GenericToDhall h) => GenericToDhall ((f :+: g) :+: M1 C c h) where
    genericToDhallWithNormalizer inputNormalizer options@(InterpretOptions {..}) = pure (Encoder {..})
      where
        embed (L1 l) =
            case maybeValL of
                Nothing   -> Field declared keyL
                Just valL -> App (Field declared keyL) valL
          where
            (keyL, maybeValL) =
              unsafeExpectUnionLit "genericToDhallWithNormalizer (:+:)" (embedL l)
        embed (R1 (M1 r)) =
            case notEmptyRecordLit (embedR r) of
                Nothing   -> Field declared keyR
                Just valR -> App (Field declared keyR) valR

        nR :: M1 i c h a
        nR = undefined

        keyR = constructorModifier (Data.Text.pack (conName nR))

        declared = Union (Dhall.Map.insert keyR (notEmptyRecord declaredR) ktsL)

        Encoder embedL declaredL = evalState (genericToDhallWithNormalizer inputNormalizer options) 1
        Encoder embedR declaredR = evalState (genericToDhallWithNormalizer inputNormalizer options) 1

        ktsL = unsafeExpectUnion "genericToDhallWithNormalizer (:+:)" declaredL

instance (Constructor c, GenericToDhall f, GenericToDhall (g :+: h)) => GenericToDhall (M1 C c f :+: (g :+: h)) where
    genericToDhallWithNormalizer inputNormalizer options@(InterpretOptions {..}) = pure (Encoder {..})
      where
        embed (L1 (M1 l)) =
            case notEmptyRecordLit (embedL l) of
                Nothing   -> Field declared keyL
                Just valL -> App (Field declared keyL) valL
        embed (R1 r) =
            case maybeValR of
                Nothing   -> Field declared keyR
                Just valR -> App (Field declared keyR) valR
          where
            (keyR, maybeValR) =
                unsafeExpectUnionLit "genericToDhallWithNormalizer (:+:)" (embedR r)

        nL :: M1 i c f a
        nL = undefined

        keyL = constructorModifier (Data.Text.pack (conName nL))

        declared = Union (Dhall.Map.insert keyL (notEmptyRecord declaredL) ktsR)

        Encoder embedL declaredL = evalState (genericToDhallWithNormalizer inputNormalizer options) 1
        Encoder embedR declaredR = evalState (genericToDhallWithNormalizer inputNormalizer options) 1

        ktsR = unsafeExpectUnion "genericToDhallWithNormalizer (:+:)" declaredR

instance (GenericToDhall (f :+: g), GenericToDhall (h :+: i)) => GenericToDhall ((f :+: g) :+: (h :+: i)) where
    genericToDhallWithNormalizer inputNormalizer options = pure (Encoder {..})
      where
        embed (L1 l) =
            case maybeValL of
                Nothing   -> Field declared keyL
                Just valL -> App (Field declared keyL) valL
          where
            (keyL, maybeValL) =
                unsafeExpectUnionLit "genericToDhallWithNormalizer (:+:)" (embedL l)
        embed (R1 r) =
            case maybeValR of
                Nothing   -> Field declared keyR
                Just valR -> App (Field declared keyR) valR
          where
            (keyR, maybeValR) =
                unsafeExpectUnionLit "genericToDhallWithNormalizer (:+:)" (embedR r)

        declared = Union (Dhall.Map.union ktsL ktsR)

        Encoder embedL declaredL = evalState (genericToDhallWithNormalizer inputNormalizer options) 1
        Encoder embedR declaredR = evalState (genericToDhallWithNormalizer inputNormalizer options) 1

        ktsL = unsafeExpectUnion "genericToDhallWithNormalizer (:+:)" declaredL
        ktsR = unsafeExpectUnion "genericToDhallWithNormalizer (:+:)" declaredR

instance (GenericToDhall (f :*: g), GenericToDhall (h :*: i)) => GenericToDhall ((f :*: g) :*: (h :*: i)) where
    genericToDhallWithNormalizer inputNormalizer options = do
        Encoder embedL declaredL <- genericToDhallWithNormalizer inputNormalizer options
        Encoder embedR declaredR <- genericToDhallWithNormalizer inputNormalizer options

        let embed (l :*: r) =
                RecordLit (Dhall.Map.union mapL mapR)
              where
                mapL =
                    unsafeExpectRecordLit "genericToDhallWithNormalizer (:*:)" (embedL l)

                mapR =
                    unsafeExpectRecordLit "genericToDhallWithNormalizer (:*:)" (embedR r)

        let declared = Record (Dhall.Map.union mapL mapR)
              where
                mapL = unsafeExpectRecord "genericToDhallWithNormalizer (:*:)" declaredL
                mapR = unsafeExpectRecord "genericToDhallWithNormalizer (:*:)" declaredR

        pure (Encoder {..})

instance (GenericToDhall (f :*: g), Selector s, ToDhall a) => GenericToDhall ((f :*: g) :*: M1 S s (K1 i a)) where
    genericToDhallWithNormalizer inputNormalizer options@InterpretOptions{..} = do
        let nR :: M1 S s (K1 i a) r
            nR = undefined

        nameR <- fmap fieldModifier (getSelName nR)

        Encoder embedL declaredL <- genericToDhallWithNormalizer inputNormalizer options

        let Encoder embedR declaredR = injectWith inputNormalizer

        let embed (l :*: M1 (K1 r)) =
                RecordLit (Dhall.Map.insert nameR (Dhall.Core.makeRecordField $ embedR r) mapL)
              where
                mapL =
                    unsafeExpectRecordLit "genericToDhallWithNormalizer (:*:)" (embedL l)

        let declared = Record (Dhall.Map.insert nameR (Dhall.Core.makeRecordField declaredR) mapL)
              where
                mapL = unsafeExpectRecord "genericToDhallWithNormalizer (:*:)" declaredL

        return (Encoder {..})

instance (Selector s, ToDhall a, GenericToDhall (f :*: g)) => GenericToDhall (M1 S s (K1 i a) :*: (f :*: g)) where
    genericToDhallWithNormalizer inputNormalizer options@InterpretOptions{..} = do
        let nL :: M1 S s (K1 i a) r
            nL = undefined

        nameL <- fmap fieldModifier (getSelName nL)

        let Encoder embedL declaredL = injectWith inputNormalizer

        Encoder embedR declaredR <- genericToDhallWithNormalizer inputNormalizer options

        let embed (M1 (K1 l) :*: r) =
                RecordLit (Dhall.Map.insert nameL (Dhall.Core.makeRecordField $ embedL l) mapR)
              where
                mapR =
                    unsafeExpectRecordLit "genericToDhallWithNormalizer (:*:)" (embedR r)

        let declared = Record (Dhall.Map.insert nameL (Dhall.Core.makeRecordField declaredL) mapR)
              where
                mapR = unsafeExpectRecord "genericToDhallWithNormalizer (:*:)" declaredR

        return (Encoder {..})

instance (Selector s1, Selector s2, ToDhall a1, ToDhall a2) => GenericToDhall (M1 S s1 (K1 i1 a1) :*: M1 S s2 (K1 i2 a2)) where
    genericToDhallWithNormalizer inputNormalizer InterpretOptions{..} = do
        let nL :: M1 S s1 (K1 i1 a1) r
            nL = undefined

        let nR :: M1 S s2 (K1 i2 a2) r
            nR = undefined

        nameL <- fmap fieldModifier (getSelName nL)
        nameR <- fmap fieldModifier (getSelName nR)

        let Encoder embedL declaredL = injectWith inputNormalizer
        let Encoder embedR declaredR = injectWith inputNormalizer

        let embed (M1 (K1 l) :*: M1 (K1 r)) =
                RecordLit $ Dhall.Core.makeRecordField <$>
                    Dhall.Map.fromList
                        [ (nameL, embedL l), (nameR, embedR r) ]


        let declared =
                Record $ Dhall.Core.makeRecordField <$>
                    Dhall.Map.fromList
                        [ (nameL, declaredL)
                        , (nameR, declaredR) ]


        return (Encoder {..})

instance GenericToDhall U1 where
    genericToDhallWithNormalizer _ _ = pure (Encoder {..})
      where
        embed _ = RecordLit mempty

        declared = Record mempty

{-| The 'RecordDecoder' applicative functor allows you to build a 'Decoder'
    from a Dhall record.

    For example, let's take the following Haskell data type:

>>> :{
data Project = Project
  { projectName :: Text
  , projectDescription :: Text
  , projectStars :: Natural
  }
:}

    And assume that we have the following Dhall record that we would like to
    parse as a @Project@:

> { name =
>     "dhall-haskell"
> , description =
>     "A configuration language guaranteed to terminate"
> , stars =
>     289
> }

    Our decoder has type 'Decoder' @Project@, but we can't build that out of any
    smaller decoders, as 'Decoder's cannot be combined (they are only 'Functor's).
    However, we can use a 'RecordDecoder' to build a 'Decoder' for @Project@:

>>> :{
project :: Decoder Project
project =
  record
    ( Project <$> field "name" strictText
              <*> field "description" strictText
              <*> field "stars" natural
    )
:}
-}

newtype RecordDecoder a =
  RecordDecoder
    ( Data.Functor.Product.Product
        ( Control.Applicative.Const
            (Dhall.Map.Map Text (Expector (Expr Src Void)))
        )
        ( Data.Functor.Compose.Compose ((->) (Expr Src Void)) (Extractor Src Void)
        )
        a
    )
  deriving (Functor, Applicative)


-- | Run a 'RecordDecoder' to build a 'Decoder'.
record :: RecordDecoder a -> Dhall.Decoder a
record
    (RecordDecoder
        (Data.Functor.Product.Pair
            (Control.Applicative.Const fields)
            (Data.Functor.Compose.Compose extract)
        )
    ) = Decoder {..}
  where
    expected = Record <$> traverse (fmap Dhall.Core.makeRecordField) fields


-- | Parse a single field of a record.
field :: Text -> Decoder a -> RecordDecoder a
field key (Decoder {..}) =
  RecordDecoder
    ( Data.Functor.Product.Pair
        ( Control.Applicative.Const
            (Dhall.Map.singleton key expected)
        )
        ( Data.Functor.Compose.Compose extractBody )
    )
  where
    extractBody expr@(RecordLit fields) = case Dhall.Core.recordFieldValue <$> Dhall.Map.lookup key fields of
      Just v -> extract v
      _      -> typeError expected expr
    extractBody expr = typeError expected expr

{-| The 'UnionDecoder' monoid allows you to build a 'Decoder' from a Dhall union

    For example, let's take the following Haskell data type:

>>> :{
data Status = Queued Natural
            | Result Text
            | Errored Text
:}

    And assume that we have the following Dhall union that we would like to
    parse as a @Status@:

> < Result : Text
> | Queued : Natural
> | Errored : Text
> >.Result "Finish successfully"

    Our decoder has type 'Decoder' @Status@, but we can't build that out of any
    smaller decoders, as 'Decoder's cannot be combined (they are only 'Functor's).
    However, we can use a 'UnionDecoder' to build a 'Decoder' for @Status@:

>>> :{
status :: Decoder Status
status = union
  (  ( Queued  <$> constructor "Queued"  natural )
  <> ( Result  <$> constructor "Result"  strictText )
  <> ( Errored <$> constructor "Errored" strictText )
  )
:}

-}
newtype UnionDecoder a =
    UnionDecoder
      ( Data.Functor.Compose.Compose (Dhall.Map.Map Text) Decoder a )
  deriving (Functor)

instance Data.Semigroup.Semigroup (UnionDecoder a) where
    (<>) = coerce ((<>) :: Dhall.Map.Map Text (Decoder a) -> Dhall.Map.Map Text (Decoder a) -> Dhall.Map.Map Text (Decoder a))

instance Monoid (UnionDecoder a) where
    mempty = coerce (mempty :: Dhall.Map.Map Text (Decoder a))
    mappend = (Data.Semigroup.<>)

-- | Run a 'UnionDecoder' to build a 'Decoder'.
union :: UnionDecoder a -> Decoder a
union (UnionDecoder (Data.Functor.Compose.Compose mp)) = Decoder {..}
  where
    extract expr = case expected' of
        Failure e -> Failure $ fmap ExpectedTypeError e
        Success x -> extract' expr x

    extract' e0 mp' = Data.Maybe.maybe (typeError expected e0) (uncurry Dhall.extract) $ do
        (fld, e1, rest) <- extractUnionConstructor e0

        t <- Dhall.Map.lookup fld mp

        guard $
            Dhall.Core.Union rest `Dhall.Core.judgmentallyEqual` Dhall.Core.Union (Dhall.Map.delete fld mp')

        pure (t, e1)

    expected = Union <$> expected'

    expected' = traverse (fmap notEmptyRecord . Dhall.expected) mp

-- | Parse a single constructor of a union
constructor :: Text -> Decoder a -> UnionDecoder a
constructor key valueDecoder = UnionDecoder
    ( Data.Functor.Compose.Compose (Dhall.Map.singleton key valueDecoder) )

-- | Infix 'divided'
(>*<) :: Divisible f => f a -> f b -> f (a, b)
(>*<) = divided

infixr 5 >*<

{-| The 'RecordEncoder' divisible (contravariant) functor allows you to build
    an 'Encoder' for a Dhall record.

    For example, let's take the following Haskell data type:

>>> :{
data Project = Project
  { projectName :: Text
  , projectDescription :: Text
  , projectStars :: Natural
  }
:}

    And assume that we have the following Dhall record that we would like to
    parse as a @Project@:

> { name =
>     "dhall-haskell"
> , description =
>     "A configuration language guaranteed to terminate"
> , stars =
>     289
> }

    Our encoder has type 'Encoder' @Project@, but we can't build that out of any
    smaller encoders, as 'Encoder's cannot be combined (they are only 'Contravariant's).
    However, we can use an 'RecordEncoder' to build an 'Encoder' for @Project@:

>>> :{
injectProject :: Encoder Project
injectProject =
  recordEncoder
    ( adapt >$< encodeFieldWith "name" inject
            >*< encodeFieldWith "description" inject
            >*< encodeFieldWith "stars" inject
    )
  where
    adapt (Project{..}) = (projectName, (projectDescription, projectStars))
:}

    Or, since we are simply using the `ToDhall` instance to inject each field, we could write

>>> :{
injectProject :: Encoder Project
injectProject =
  recordEncoder
    ( adapt >$< encodeField "name"
            >*< encodeField "description"
            >*< encodeField "stars"
    )
  where
    adapt (Project{..}) = (projectName, (projectDescription, projectStars))
:}

-}

newtype RecordEncoder a
  = RecordEncoder (Dhall.Map.Map Text (Encoder a))

instance Contravariant RecordEncoder where
  contramap f (RecordEncoder encodeTypeRecord) = RecordEncoder $ contramap f <$> encodeTypeRecord

instance Divisible RecordEncoder where
  divide f (RecordEncoder bEncoderRecord) (RecordEncoder cEncoderRecord) =
      RecordEncoder
    $ Dhall.Map.union
      ((contramap $ fst . f) <$> bEncoderRecord)
      ((contramap $ snd . f) <$> cEncoderRecord)
  conquer = RecordEncoder mempty

{-| Specify how to encode one field of a record by supplying an explicit
    `Encoder` for that field
-}
encodeFieldWith :: Text -> Encoder a -> RecordEncoder a
encodeFieldWith name encodeType = RecordEncoder $ Dhall.Map.singleton name encodeType

{-| Specify how to encode one field of a record using the default `ToDhall`
    instance for that type
-}
encodeField :: ToDhall a => Text -> RecordEncoder a
encodeField name = encodeFieldWith name inject

-- | Convert a `RecordEncoder` into the equivalent `Encoder`
recordEncoder :: RecordEncoder a -> Encoder a
recordEncoder (RecordEncoder encodeTypeRecord) = Encoder makeRecordLit recordType
  where
    recordType = Record $ (Dhall.Core.makeRecordField . declared) <$> encodeTypeRecord
    makeRecordLit x = RecordLit $ (Dhall.Core.makeRecordField . ($ x) . embed) <$> encodeTypeRecord

{-| 'UnionEncoder' allows you to build an 'Encoder' for a Dhall record.

    For example, let's take the following Haskell data type:

>>> :{
data Status = Queued Natural
            | Result Text
            | Errored Text
:}

    And assume that we have the following Dhall union that we would like to
    parse as a @Status@:

> < Result : Text
> | Queued : Natural
> | Errored : Text
> >.Result "Finish successfully"

    Our encoder has type 'Encoder' @Status@, but we can't build that out of any
    smaller encoders, as 'Encoder's cannot be combined.
    However, we can use an 'UnionEncoder' to build an 'Encoder' for @Status@:

>>> :{
injectStatus :: Encoder Status
injectStatus = adapt >$< unionEncoder
  (   encodeConstructorWith "Queued"  inject
  >|< encodeConstructorWith "Result"  inject
  >|< encodeConstructorWith "Errored" inject
  )
  where
    adapt (Queued  n) = Left n
    adapt (Result  t) = Right (Left t)
    adapt (Errored e) = Right (Right e)
:}

    Or, since we are simply using the `ToDhall` instance to inject each branch, we could write

>>> :{
injectStatus :: Encoder Status
injectStatus = adapt >$< unionEncoder
  (   encodeConstructor "Queued"
  >|< encodeConstructor "Result"
  >|< encodeConstructor "Errored"
  )
  where
    adapt (Queued  n) = Left n
    adapt (Result  t) = Right (Left t)
    adapt (Errored e) = Right (Right e)
:}

-}
newtype UnionEncoder a =
  UnionEncoder
    ( Data.Functor.Product.Product
        ( Control.Applicative.Const
            ( Dhall.Map.Map
                Text
                ( Expr Src Void )
            )
        )
        ( Op (Text, Expr Src Void) )
        a
    )
  deriving (Contravariant)

-- | Combines two 'UnionEncoder' values.  See 'UnionEncoder' for usage
-- notes.
--
-- Ideally, this matches 'Data.Functor.Contravariant.Divisible.chosen';
-- however, this allows 'UnionEncoder' to not need a 'Divisible' instance
-- itself (since no instance is possible).
(>|<) :: UnionEncoder a -> UnionEncoder b -> UnionEncoder (Either a b)
UnionEncoder (Data.Functor.Product.Pair (Control.Applicative.Const mx) (Op fx))
    >|< UnionEncoder (Data.Functor.Product.Pair (Control.Applicative.Const my) (Op fy)) =
    UnionEncoder
      ( Data.Functor.Product.Pair
          ( Control.Applicative.Const (mx <> my) )
          ( Op (either fx fy) )
      )

infixr 5 >|<

-- | Convert a `UnionEncoder` into the equivalent `Encoder`
unionEncoder :: UnionEncoder a -> Encoder a
unionEncoder ( UnionEncoder ( Data.Functor.Product.Pair ( Control.Applicative.Const fields ) ( Op embedF ) ) ) =
    Encoder
      { embed = \x ->
          let (name, y) = embedF x
          in  case notEmptyRecordLit y of
                  Nothing  -> Field (Union fields') name
                  Just val -> App (Field (Union fields') name) val
      , declared =
          Union fields'
      }
  where
    fields' = fmap notEmptyRecord fields

{-| Specify how to encode an alternative by providing an explicit `Encoder`
    for that alternative
-}
encodeConstructorWith
    :: Text
    -> Encoder a
    -> UnionEncoder a
encodeConstructorWith name encodeType = UnionEncoder $
    Data.Functor.Product.Pair
      ( Control.Applicative.Const
          ( Dhall.Map.singleton
              name
              ( declared encodeType )
          )
      )
      ( Op ( (name,) . embed encodeType )
      )

{-| Specify how to encode an alternative by using the default `ToDhall` instance
    for that type
-}
encodeConstructor
    :: ToDhall a
    => Text
    -> UnionEncoder a
encodeConstructor name = encodeConstructorWith name inject
