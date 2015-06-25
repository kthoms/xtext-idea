/** 
 * Copyright (c) 2015 itemis AG (http://www.itemis.eu) and others.
 * All rights reserved. This program and the accompanying materials
 * are made available under the terms of the Eclipse Public License v1.0
 * which accompanies this distribution, and is available at
 * http://www.eclipse.org/legal/epl-v10.html
 */
package org.eclipse.xtext.idea.build

import com.google.inject.Inject
import com.google.inject.Provider
import com.intellij.ProjectTopics
import com.intellij.compiler.ModuleCompilerUtil
import com.intellij.openapi.Disposable
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.application.ModalityState
import com.intellij.openapi.components.AbstractProjectComponent
import com.intellij.openapi.editor.EditorFactory
import com.intellij.openapi.editor.event.DocumentAdapter
import com.intellij.openapi.editor.event.DocumentEvent
import com.intellij.openapi.fileEditor.FileDocumentManager
import com.intellij.openapi.module.Module
import com.intellij.openapi.module.ModuleManager
import com.intellij.openapi.progress.ProcessCanceledException
import com.intellij.openapi.project.Project
import com.intellij.openapi.roots.ModuleRootAdapter
import com.intellij.openapi.roots.ModuleRootEvent
import com.intellij.openapi.roots.ModuleRootManager
import com.intellij.openapi.roots.ProjectFileIndex
import com.intellij.openapi.util.Disposer
import com.intellij.openapi.vfs.VirtualFile
import com.intellij.openapi.vfs.VirtualFileAdapter
import com.intellij.openapi.vfs.VirtualFileEvent
import com.intellij.openapi.vfs.VirtualFileManager
import com.intellij.openapi.vfs.VirtualFileMoveEvent
import com.intellij.psi.PsiJavaFile
import com.intellij.psi.PsiManager
import com.intellij.psi.impl.PsiModificationTrackerImpl
import com.intellij.util.Alarm
import com.intellij.util.graph.Graph
import com.intellij.util.messages.MessageBusConnection
import java.util.ArrayList
import java.util.HashSet
import java.util.List
import java.util.Map
import java.util.Set
import java.util.concurrent.BlockingQueue
import java.util.concurrent.LinkedBlockingQueue
import org.eclipse.emf.common.util.URI
import org.eclipse.xtext.build.BuildRequest
import org.eclipse.xtext.build.IncrementalBuilder
import org.eclipse.xtext.build.IndexState
import org.eclipse.xtext.build.Source2GeneratedMapping
import org.eclipse.xtext.common.types.descriptions.TypeResourceDescription.ChangedDelta
import org.eclipse.xtext.idea.resource.IdeaResourceSetProvider
import org.eclipse.xtext.idea.resource.IdeaResourceSetProvider.VirtualFileBasedUriHandler
import org.eclipse.xtext.idea.shared.IdeaSharedInjectorProvider
import org.eclipse.xtext.naming.IQualifiedNameConverter
import org.eclipse.xtext.resource.IResourceDescription
import org.eclipse.xtext.resource.IResourceDescription.Delta
import org.eclipse.xtext.resource.IResourceServiceProvider
import org.eclipse.xtext.resource.impl.ChunkedResourceDescriptions
import org.eclipse.xtext.resource.impl.ResourceDescriptionsData
import org.eclipse.xtext.util.internal.Log

import static org.eclipse.xtext.idea.build.BuildEvent.Type.*
import static org.eclipse.xtext.idea.build.XtextAutoBuilderComponent.*

import static extension org.eclipse.xtext.idea.resource.VirtualFileURIUtil.*
import org.eclipse.emf.ecore.resource.ResourceSet

/**
 * @author Jan Koehnlein - Initial contribution and API
 */
@Log class XtextAutoBuilderComponent extends AbstractProjectComponent implements Disposable {
	
	volatile boolean disposed
	
	BlockingQueue<BuildEvent> queue = new LinkedBlockingQueue<BuildEvent>()

	Alarm alarm 

	Project project
	
	@Inject Provider<IncrementalBuilder> builderProvider	
	
	@Inject Provider<BuildProgressReporter> buildProgressReporterProvider
	 
	@Inject IdeaResourceSetProvider resourceSetProvider
	
	@Inject IResourceServiceProvider.Registry resourceServiceProviderRegistry
	
	@Inject IQualifiedNameConverter qualifiedNameConverter
	
	@Inject ChunkedResourceDescriptions chunkedResourceDescriptions
	
	Map<Module, Source2GeneratedMapping> module2GeneratedMapping = newHashMap() 
	
	new(Project project) {
		super(project)
		TEST_MODE = ApplicationManager.application.isUnitTestMode
		IdeaSharedInjectorProvider.injector.injectMembers(this)
		this.project = project
		alarm = new Alarm(Alarm.ThreadToUse.OWN_THREAD, this)
		disposed = false
		Disposer.register(project, this)
	
		EditorFactory.getInstance().getEventMulticaster().addDocumentListener(new DocumentAdapter() {
			override void documentChanged(DocumentEvent event) {
				var file = FileDocumentManager.getInstance().getFile(event.getDocument())
				if (file != null) {
					fileModified(file)
				} else {
					LOG.info("No virtual file for document. Contents was "+event.document)
				}
			}
		}, project)
		
		VirtualFileManager.getInstance().addVirtualFileListener(new VirtualFileAdapter() {
			override void contentsChanged(VirtualFileEvent event) {
				fileModified(event.getFile())
			}

			override void fileCreated(VirtualFileEvent event) {
				fileAdded(event.getFile())
			}

			override void fileDeleted(VirtualFileEvent event) {
				fileDeleted(event.getFile())
			}
			
			override void fileMoved(VirtualFileMoveEvent event) {
				// TODO deal with that!
			}
		}, project)
		
		val MessageBusConnection connection = project.getMessageBus().connect(project);
         connection.subscribe(ProjectTopics.PROJECT_ROOTS, new ModuleRootAdapter() {
										
			override rootsChanged(ModuleRootEvent event) {
				doCleanBuild
			}
         	
         });
		
		alarm = new Alarm(Alarm.ThreadToUse.OWN_THREAD, project)
	}
	
	override dispose() {
		disposed = true
		alarm.cancelAllRequests
		queue.clear
		chunkedResourceDescriptions = null
	}
	
	protected def getProject() {
		return myProject
	}
	
	def void fileModified(VirtualFile file) {
		enqueue(file, MODIFIED)
	}

	def void fileDeleted(VirtualFile file) {
		enqueue(file, DELETED)
	}

	def void fileAdded(VirtualFile file) {
		if (!file.isDirectory && file.length > 0) {
			enqueue(file, ADDED)
		} else {
			if (LOG.infoEnabled)
				LOG.info("Ignoring new empty file "+file.path+". Waiting for content.")
		}
	}
	
	/**
	 * For testing purposes! When set to <code>true</code>, the builds are not running asynchronously and delayed, but directly when the event comes in
	 */
	public static boolean TEST_MODE = false

	protected def enqueue(VirtualFile file, BuildEvent.Type type) {
		if (isExcluded(file)) {
			return;
		}
		if (!disposed && !isLoaded) {
			queueAllResources
		}
		if (LOG.isInfoEnabled) {
			LOG.info("Queuing "+type+" - "+file.URI+".")
		}
		if (file != null && !disposed) {
			queue.put(new BuildEvent(file, type))
			doRunBuild()
		}
	}
	
	protected def doCleanBuild() {
		module2GeneratedMapping.clear
		queueAllResources
		doRunBuild
	}
	
	protected def doRunBuild() {
		if (TEST_MODE) {
			(PsiManager.getInstance(getProject()).getModificationTracker() as PsiModificationTrackerImpl).incCounter();
			build
		} else {
			alarm.cancelAllRequests
			alarm.addRequest([build], 200)
		}
	}
	
	protected def boolean isExcluded(VirtualFile file) {
		if (ignoreIncomingEvents) {
			if (LOG.isDebugEnabled) 
				LOG.debug("Ignoring transitive file change "+file.path)
			return true;
		}
		return file == null 
			|| file.isDirectory 
	}
	
	protected def boolean isLoaded() {
		return !chunkedResourceDescriptions.isEmpty || !queue.isEmpty
	}
	
	protected def queueAllResources() {
		val baseFile = project.baseDir
		baseFile.visitFileTree[ file |
			if (!file.isDirectory && file.exists) {
				queue.put(new BuildEvent(file, BuildEvent.Type.ADDED))
			}
		]
	}
	
	def void visitFileTree(VirtualFile file, (VirtualFile)=>void handler) {
		if (file.isDirectory) {
			for (child : file.children) {
				visitFileTree(child, handler)
			}
		}
		handler.apply(file)
	}
	
	private volatile boolean ignoreIncomingEvents = false
	
	protected def void build() {
		if (disposed) {
			return
		}
		val allEvents = newArrayList
		queue.drainTo(allEvents)
		internalBuild(allEvents)
	}
	
	protected def void internalBuild(List<BuildEvent> allEvents) {
		val app = ApplicationManager.application
		val moduleManager = ModuleManager.getInstance(getProject)
		val buildProgressReporter = buildProgressReporterProvider.get 
		buildProgressReporter.project = project
		try {
			val fileIndex = ProjectFileIndex.SERVICE.getInstance(project)
			val moduleGraph = app.<Graph<Module>>runReadAction[moduleManager.moduleGraph]
			// deltas are added over the whole build
			val deltas = <IResourceDescription.Delta>newArrayList
			val sortedModules = new ArrayList(moduleGraph.nodes)
			ModuleCompilerUtil.sortModules(project, sortedModules)
			for (module: sortedModules) {
				val fileMappings = module2GeneratedMapping.get(module) ?: new Source2GeneratedMapping
				val moduleDescriptions = chunkedResourceDescriptions.getContainer(module.name) ?: new ResourceDescriptionsData(emptyList)
				val changedUris = newHashSet
				val deletedUris = newHashSet
				val contentRoots = ModuleRootManager.getInstance(module).contentRoots
				val events = allEvents.filter[event| event.findModule(fileIndex) == module].toSet
				if (contentRoots.empty 
					|| events.isEmpty && deltas.isEmpty) {
					LOG.info("Skipping module '"+module.name+"'. Nothing to do here.")		
				} else {
					collectChanges(events, module, changedUris, deletedUris, deltas)
					
					val newIndex = moduleDescriptions.copy
					
					val request = new BuildRequest => [
						resourceSet = createResourceSet(module, newIndex)
						dirtyFiles += changedUris
						deletedFiles += deletedUris
						externalDeltas += deltas
						baseDir = contentRoots.head.URI
						// outputs = ??
						previousState = new IndexState(moduleDescriptions, fileMappings)
						newState = new IndexState(newIndex, fileMappings.copy)
	
						afterValidate = buildProgressReporter
						afterDeleteFile = [
							buildProgressReporter.markAsAffected(it)
						]
					]
					val result = app.<IncrementalBuilder.Result>runReadAction [
						builderProvider.get().build(request, resourceServiceProviderRegistry)
					]
					app.invokeAndWait([
						app.runWriteAction [
							try {
								ignoreIncomingEvents = true
								val handler = VirtualFileBasedUriHandler.find(request.resourceSet)
								handler.flushToDisk
							} finally {
								ignoreIncomingEvents = false
							}
						]
					], ModalityState.any)
					chunkedResourceDescriptions.setContainer(module.name, result.indexState.resourceDescriptions)
					module2GeneratedMapping.put(module, result.indexState.fileMappings)
					deltas.addAll(result.affectedResources)
				}
			}
		} catch(ProcessCanceledException exc) {
			queue.addAll(allEvents)
		} finally {
			buildProgressReporter.clearProgress
		}
	}
	
	def createResourceSet(Module module, ResourceDescriptionsData newData) {
		val result = resourceSetProvider.get(module)
		val fullIndex = ChunkedResourceDescriptions.findInEmfObject(result)
		fullIndex.setContainer(module.name, newData)
		return result
	}
	
	def String getContainerHandle(Module module) {
		return module.name
	}
	
	protected def collectChanges(Set<BuildEvent> events, Module module, HashSet<URI> changedUris, HashSet<URI> deletedUris, ArrayList<Delta> deltas) {
		val app = ApplicationManager.application
		val fileMappings = module2GeneratedMapping.get(module)
		for (event : events) {
			switch event.type {
				case MODIFIED,
				case ADDED: {
					val uri = event.file.URI
					val sourceUris = fileMappings?.getSource(uri)
					if (sourceUris != null && !sourceUris.isEmpty) {
						for (sourceUri : sourceUris) {
							changedUris += sourceUri
						}									
					} else if (isJavaFile(event.file)) {
						deltas += app.<Set<IResourceDescription.Delta>>runReadAction [
							return getJavaDeltas(event.file, module)
						]
					} else {
						changedUris += uri
					}
				}
				case DELETED : {
					val uri = event.file.URI
					val sourceUris = fileMappings?.getSource(uri)
					if (sourceUris != null && !sourceUris.isEmpty) {
						for (sourceUri : sourceUris) {
							changedUris += sourceUri
						}									
					} else if (isJavaFile(event.file)) {
						deltas += app.<Set<IResourceDescription.Delta>>runReadAction [
							getJavaDeltas(event.file, module)
						]
					} else {
						deletedUris += uri
					}
				}
			}
		}
	}
	
	def boolean isJavaFile(VirtualFile file) {
		file.extension == 'java'
	}
	
	def Set<IResourceDescription.Delta> getJavaDeltas(VirtualFile file, Module module) {
		if (!file.isValid) {
			return emptySet
		}
		val psiFile = PsiManager.getInstance(module.project).findFile(file)
		val result = <IResourceDescription.Delta>newLinkedHashSet
		if (psiFile instanceof PsiJavaFile) {
			for (clazz : psiFile.classes) {
				result += new ChangedDelta(qualifiedNameConverter.toQualifiedName(clazz.qualifiedName)) 
			}
		}
		return result
	}
	
	public def ChunkedResourceDescriptions installCopyOfResourceDescriptions(ResourceSet resourceSet) {
		return chunkedResourceDescriptions.createShallowCopyWith(resourceSet)
	}

	protected def findModule(BuildEvent it, ProjectFileIndex fileIndex) {
		if (type == DELETED)
			file.findModule(fileIndex)
		else
			fileIndex.getModuleForFile(file, true)
	}
	
	protected def Module findModule(VirtualFile file, ProjectFileIndex fileIndex) {
		if (file == null) {
			return null
		}
		val module = fileIndex.getModuleForFile(file, true)
		if (module != null)
			return module
		return file.parent.findModule(fileIndex)
	}
	
	override String getComponentName() {
		return "Xtext Compiler Component"
	}
	
}
