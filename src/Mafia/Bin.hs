{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
module Mafia.Bin
  ( BinError(..)
  , renderBinError

  , InstallPackage(..)
  , ipackageId
  , renderInstallPackage
  , ipkgName
  , ipkgVersion

  , installBinary
  , ensureExeOnPath
  ) where

import           Control.Monad.IO.Class (MonadIO(..))

import           Data.Text (Text)
import qualified Data.Text as T

import           Mafia.Home
import           Mafia.IO
import           Mafia.Install
import           Mafia.Package
import           Mafia.Path
import           Mafia.Cabal.Types
import           P

import           System.IO (IO)
import           System.Posix.Files (createSymbolicLink)

import           X.Control.Monad.Trans.Either (EitherT, left)


data BinError =
    BinInstallError InstallError
  | BinNotExecutable PackageId
    deriving (Show)

renderBinError :: BinError -> Text
renderBinError = \case
  BinInstallError err ->
    renderInstallError err
  BinNotExecutable pid ->
    "Cannot link bin/ directory for " <> renderPackageId pid <> " as no executables were installed."

data InstallPackage =
    InstallPackageName PackageName
  | InstallPackageId PackageId
    deriving (Eq, Ord, Show)

ipackageId :: Text -> [Int] -> InstallPackage
ipackageId name ver =
  InstallPackageId (packageId name ver)

renderInstallPackage :: InstallPackage -> Text
renderInstallPackage = \case
  InstallPackageName name ->
    unPackageName name
  InstallPackageId pid ->
    renderPackageId pid

ipkgName :: InstallPackage -> PackageName
ipkgName = \case
  InstallPackageName name ->
    name
  InstallPackageId pid ->
    pkgName pid

ipkgVersion :: InstallPackage -> Maybe Version
ipkgVersion = \case
  InstallPackageName _ ->
    Nothing
  InstallPackageId pid ->
    Just (pkgVersion pid)

-- | Installs a given cabal package at a specific version and return a directory containing all executables
installBinary :: InstallPackage -> EitherT BinError IO Directory
installBinary ipkg = do
  bin <- ensureMafiaDir "bin"

  let
    plink = bin </> renderInstallPackage ipkg
    pdir = plink <> "/"
    pbin = plink <> "/bin"

  unlessM (doesDirectoryExist pdir) $ do
    -- if the directory doesn't exist, but there happens to be a file there, we
    -- must have a dead symlink, so lets remove it and install it again.
    ignoreIO $ removeFile plink

    pkg <- firstT BinInstallError $ installPackage (ipkgName ipkg) (ipkgVersion ipkg)
    env <- firstT BinInstallError $ getPackageEnv
    let gdir = packageSandboxDir env pkg

    unlessM (doesDirectoryExist $ gdir </> "bin") $
      left (BinNotExecutable . refId $ pkgRef pkg)

    liftIO $ createSymbolicLink (T.unpack gdir) (T.unpack plink)

  return pbin

ensureExeOnPath :: InstallPackage -> EitherT BinError IO ()
ensureExeOnPath pkg = do
  dir <- installBinary pkg
  setEnv "PATH" . maybe dir (\path -> dir <> ":" <> path) =<< lookupEnv "PATH"
