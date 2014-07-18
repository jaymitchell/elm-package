{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Get.Install (install, installAll) where

import Control.Monad.Error
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.Maybe (mapMaybe)
import qualified Data.ByteString.Lazy as BS
import qualified Data.Map as Map
import System.Directory
import System.FilePath

import qualified Elm.Internal.Dependencies as D
import qualified Elm.Internal.Libraries as L
import qualified Elm.Internal.Name as N
import qualified Elm.Internal.Paths as EPath
import qualified Elm.Internal.Version as V

import Get.Library (Library)
import qualified Utils.Commands as Cmd
import qualified Utils.Paths as Path
import Utils.ResolveDeps

-- | External Interface
installAll :: ErrorT String IO ()
installAll =
  do deps <- D.depsAt EPath.dependencyFile
     libs <- solveConstraints deps
     currVersions <- L.getVersionsSafe EPath.librariesFile
     let diffList = computeDiff currVersions libs
     let (_, libsToInstall) = unzip diffList
     confirmed <- liftIO $ offerInstallPlan diffList
     case confirmed of
       False -> liftIO $ putStrLn "Bye."
       True ->
         do forM_ libsToInstall install1
            liftIO $ do
              writeLibraries libs
              putStrLn "Success!"

-- | Just a synonym to tuple type which is used a lot in this module
type Lib = (N.Name, V.Version)

-- | Datatype describing whether a particular library will be installed first time,
--   or is updated from previous version
data LibChange = LibFresh
               | LibUpdate V.Version

-- | Human-readable representation of previous datatype. Used to show "install plan"
showUpdate :: (LibChange, Lib) -> String
showUpdate (change, (name, new)) = case change of
  LibFresh -> concat ["new: ", show name, " (", show new, ")"]
  LibUpdate old -> concat ["upd: ", show name, " (", show old, " -> ", show new, ")"]

-- | Compute differences between currently installed libraries and new constraint solver result
computeDiff :: Maybe [Lib] -> [Lib] -> [(LibChange, Lib)]
computeDiff old new =
  case old of
    Nothing -> map (\x -> (LibFresh, x)) new
    Just libs ->
      let libsMap = Map.fromList libs
          change lib@(name, version) = case Map.lookup name libsMap of
            Just oldVersion ->
              if oldVersion == version
              then Nothing
              else Just $ (LibUpdate oldVersion, lib)
            Nothing -> Just $ (LibFresh, lib)
      in mapMaybe change new

-- | Print "install plan" to a used, ask to proceed
offerInstallPlan :: [(LibChange, Lib)] -> IO Bool
offerInstallPlan ls = case ls of
  [] -> do putStrLn "Nothing to install"
           return False
  _ -> do putStrLn "The following libraries will be installed:"
          mapM_ (putStrLn . showUpdate) ls
          putStr "Proceed? (y/n) "
          Cmd.yesOrNo

install :: Library -> ErrorT String IO ()
install _ = throwError "TODO: implement me"

-- | Write installed libraries to elm_dependencies/elm_libraries.json, which is used by compiler
writeLibraries :: [Lib] -> IO ()
writeLibraries pairs =
  do let fromPair (n, v) = L.Library n v
         libraries = map fromPair pairs
     createDirectoryIfMissing True EPath.dependencyDirectory
     BS.writeFile EPath.librariesFile (encodePretty $ L.Libraries libraries)

install1 :: Lib -> ErrorT String IO ()
install1 (name, version) =
  Cmd.inDir EPath.dependencyDirectory $
  do repo <- Cmd.inDir Path.internals $ getRepoPath name version
     liftIO $ createDirectoryIfMissing True repo
     Cmd.copyDir (Path.internals </> repo) (repo </> show version)

-- | Fetch (or update) a repository with given name, check out requested version,
--   return a folder with package contents
getRepoPath :: N.Name -> V.Version -> ErrorT String IO FilePath
getRepoPath name version =
  do let directory = N.toFilePath name
     exists <- liftIO $ doesDirectoryExist directory
     (if exists then update else clone) name directory
     Cmd.inDir directory (checkout version)
     return directory
  where
    update name directory =
      do Cmd.out $ "Getting updates for repo " ++ show name
         Cmd.inDir directory $ do Cmd.git ["checkout", "master"]
                                  Cmd.git ["pull"]
         return ()

    clone name directory =
      do Cmd.out $ "Cloning repo " ++ show name
         Cmd.git [ "clone", "--progress", "https://github.com/" ++ show name ++ ".git" ]
         liftIO $ renameDirectory (N.project name) directory

    checkout version =
      do let tag = show version
         Cmd.out $ "Checking out version " ++ tag
         Cmd.git [ "checkout", "tags/" ++ tag ]
