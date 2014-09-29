module Install where

import Control.Monad.Error
import Data.Function (on)
import qualified Data.List as List
import qualified Data.Map as Map
import System.Directory (doesFileExist, removeDirectoryRecursive)
import System.FilePath ((</>))

import qualified Elm.Package.Constraint as Constraint
import qualified Elm.Package.Description as Desc
import qualified Elm.Package.Dependencies as Dependencies
import qualified Elm.Package.Name as N
import qualified Elm.Package.Paths as Path
import qualified Elm.Package.Version as V

import qualified Install.Fetch as Fetch
import qualified Install.Plan as Plan
import qualified Utils.Commands as Cmd


install :: Maybe (String, Maybe String) -> ErrorT String IO ()
install maybePackage =
    case maybePackage of
      Nothing ->
          upgrade

      Just (rawName, maybeRawVersion) ->
          do  (name, maybeVersion) <- parseInput rawName maybeRawVersion
              updateDescription name maybeVersion
              upgrade


parseInput :: String -> Maybe String -> ErrorT String IO (N.Name, Maybe V.Version)
parseInput rawName maybeRawVersion =
  do  name <- parseName rawName
      vrsn <- parseVersion maybeRawVersion
      return (name, vrsn)
  where
    parseName rawName =
        maybe (throwError $ invalidName rawName) return (N.fromString rawName)

    invalidName name =
        "The package name '" ++ name ++ "' is not valid. It must look like evancz/elm-html"

    parseVersion maybeVersion =
        case maybeVersion of
          Nothing -> return Nothing
          Just rawVersion ->
              maybe (throwError $ invalidVersion rawVersion) (return . Just) (V.fromString rawVersion)

    invalidVersion vrsn =
        "The version number '" ++ vrsn ++ "' is not valid. It must look like X.Y.Z"


-- INSTALL EVERYTHING

upgrade :: ErrorT String IO ()
upgrade =
  do  description <- Desc.read

      newSolution <- (error "solveConstraints") (Desc.dependencies description)
      oldSolution <- Dependencies.readSolutionOr Path.solvedDependencies (return Map.empty)
      let plan = Plan.create oldSolution newSolution

      approve <- liftIO $ getApproval plan

      if approve
          then runPlan oldSolution newSolution plan
          else liftIO $ putStrLn "Okay, I did not change anything!"            


getApproval :: Plan.Plan -> IO Bool
getApproval plan =
  do  putStrLn "To install we must make the following changes:"
      putStrLn (Plan.display plan)
      putStr "Do you approve of this plan? (y/n)"
      Cmd.yesOrNo


runPlan :: Dependencies.Solution -> Dependencies.Solution -> Plan.Plan -> ErrorT String IO ()
runPlan oldSolution newSolution plan =
  do  -- fetch new dependencies
      Cmd.inDir Path.packagesDirectory $
          mapM_ (uncurry Fetch.package) installs

      -- try to build new dependencies
      liftIO (writeSolution newSolution)
      success <- error "try to build everything"

      -- remove dependencies that are not needed
      Cmd.inDir Path.packagesDirectory $
          liftIO $ mapM_ remove (if success then removals else installs)

      -- revert solution if needed
      when (not success) $
          liftIO (writeSolution oldSolution)

      liftIO $ putStrLn (if success then "Success!" else failureMsg)
  where
    installs =
        Map.toList (Plan.installs plan)
        ++ Map.toList (Map.map snd (Plan.upgrades plan))

    removals =
        Map.toList (Plan.removals plan)
        ++ Map.toList (Map.map fst (Plan.upgrades plan))

    remove (name, version) =
        removeDirectoryRecursive (N.toFilePath name </> V.toString version)

    writeSolution =
        Dependencies.writeSolution (Path.packagesDirectory </> Path.solvedDependencies)

    failureMsg =
        "I could not build the new packages, so I have reverted to your previous\n\
        \configuration. I reported the error so no one else has to go through this\n\
        \trouble!"


-- MODIFY DESCRIPTION

updateDescription :: N.Name -> Maybe V.Version -> ErrorT String IO ()
updateDescription name maybeVersion =
  do  version <- getVersion

      exists <- liftIO (doesFileExist Path.description)
      desc <- if exists then Desc.read else return Desc.defaultDescription

      addConstraint desc name version
  where
    getVersion =
        case maybeVersion of
          Just version ->
              return version

          Nothing ->
              do  libDb <- error "readLibraries"
                  case Map.lookup (N.toString name) libDb of
                    Just versions ->
                      return $ maximum $ (error "versions") versions

                    Nothing ->
                      throwError $ "Library " ++ N.toString name ++ " wasn't found!"


addConstraint :: Desc.Description -> N.Name -> V.Version -> ErrorT String IO ()
addConstraint description name version =
  do  confirm <- liftIO confirmChange
      case confirm of
        False -> throwError noConfirmation
        True ->
            liftIO $ Desc.write $ description { Desc.dependencies = newConstraints }
  where
    newConstraints =
        List.insertBy
            (compare `on` fst)
            (name, Constraint.exactly version)
            (Desc.dependencies description)

    noConfirmation =
        "Cannot install the new package without changing " ++ Path.description ++ ".\n" ++
        "It may be easiest to modify it manually and then run 'elm-package install'."

    confirmChange =
        do  putStrLn $ "I am about to add " ++ N.toString name ++ " " ++ V.toString version ++ " to " ++ Path.description
            case List.lookup name (Desc.dependencies description) of
              Nothing -> return ()
              Just constraint ->
                  putStrLn $ "This will replace the existing constraint \"" ++ Constraint.toString constraint ++ "\""

            putStr "Would you like to proceed? (y/n) "
            Cmd.yesOrNo