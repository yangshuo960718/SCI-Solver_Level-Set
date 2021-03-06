GPUTUM: Level-Set
====================

GPUTUM Level-Set is a C++/CUDA library written to solve a system of level set equations on unstructured meshes. It is designed to solve the equations quickly by using GPU hardware.

The code was written by Zhisong Fu at the Scientific Computing and Imaging Institute, 
University of Utah, Salt Lake City, USA. The theory behind this code is published in the papers linked below. 
Table of Contents
========
<img src="https://raw.githubusercontent.com/SCIInstitute/SCI-Solver_Level-Set/master/src/Resources/levelset.gif"  align="right" hspace="20" width=450>
- [LevelSet Aknowledgements](#levelset-aknowledgements)
- [Requirements](#requirements)
- [Building](#building)<br/>
		- [Linux / OSX](#linux-and-osx)<br/>
		- [Windows](#windows)<br/>
- [Running Examples](#running-examples)
- [Using the Library](#using-the-library)
- [Testing](#testing)<br/>

<br/><br/><br/><br/><br/><br/><br/><br/>

<h4>LevelSet Aknowledgements</h4>
**<a href ="http://onlinelibrary.wiley.com/doi/10.1002/cpe.3320/full">Fast Parallel Solver for the 
Levelset Equations on Unstructured Meshes</a>**<br/>
<img src="https://raw.githubusercontent.com/SCIInstitute/SCI-Solver_Level-Set/master/src/Resources/sphere.gif"  align="right" hspace="20" width=460>

**AUTHORS:**
<br/>Zhisong Fu(*a*) <br/>
Sergey Yakovlev(*b*) <br/>
Robert M. Kirby(*a*) <br/>
Ross T. Whitaker(*a*) <br/>

This library solves for the LevelSet values on vertices located on a tetrahedral mesh. Several mesh formats
are supported, and are read by the <a href="http://wias-berlin.de/software/tetgen/">TetGen Library</a>. 
The <a href="http://glaros.dtc.umn.edu/gkhome/metis/metis/download">METIS library</a> is used to partition unstructured 
meshes. <a href="https://code.google.com/p/googletest/">
Google Test</a> is used for testing.
<br/><br/>
Requirements
==============

 * Git, CMake (2.8+ recommended), and the standard system build environment tools.
 * You will need a CUDA Compatible Graphics card. See <a href="https://developer.nvidia.com/cuda-gpus">here</a> You will also need to be sure your card has CUDA compute capability of at least 2.0.
 * SCI-Solver_Level-Set is compatible with the latest CUDA toolkit (7.5). Download <a href="https://developer.nvidia.com/cuda-downloads">here</a>.
 * This project has been tested on OpenSuse 13.1 (Bottle) on NVidia GeForce GTX 680 HD, Windows 10 on NVidia GeForce GTX 775M, and OSX 10.10 on NVidia GeForce GTX 775M. 
 * If you have a CUDA graphics card equal to or greater than our test machines and are experiencing issues, please contact the repository owners.
 * Windows: You will need Microsoft Visual Studio 2010+ build tools. This document describes the "NMake" process.
 * OSX: Please be sure to follow setup for CUDA <a href="http://docs.nvidia.com/cuda/cuda-getting-started-guide-for-mac-os-x/#axzz3W4nXNNin">here</a>. There are several compatability requirements for different MAC machines, including using a different version of CUDA (ie. 5.5).

Building
==============

<h3>Linux and OSX</h3>
In a terminal:

```console
mkdir SCI-Solver_Level-Set/build
cd SCI-Solver_Level-Set/build
cmake ../src
make
```

<h3>Windows</h3>
Open a Visual Studio (32 or 64 bit) Native Tools Command Prompt. 
Follow these commands:

```console
mkdir C:\Path\To\SCI-Solver_Level-Set\build
cd C:\Path\To\SCI-Solver_Level-Set\build
cmake -G "NMake Makefiles" ..\src
nmake
```

**Note:** For all platforms, you may need to specify your CUDA toolkit location (especially if you have multiple CUDA versions installed):

```console
cmake -DCUDA_TOOLKIT_ROOT_DIR="~/NVIDIA/CUDA-7.5" ../src
```
(Assuming this is the location).

**Note:** If you have compile errors such as <code>undefined reference: atomicAdd</code>, it is likely you need to set your compute capability manually. CMake outputs whether compute capability was determined automatically, or if you need to set it manually. The default minimum compute capability is 2.0.

```console
cmake -DCUDA_COMPUTE_CAPABILITY=20 ../src
make
```

Running Examples
==============

You will need to enable examples in your build to compile and run them.

```console
cmake -DBUILD_EXAMPLES=ON ../src
make
```

You will find the example binaries built in the <code>build/examples</code> directory.

Run the example in the build directory:

```console
examples/Example1 
```
Each example has a <code>-h</code> flag that prints options for that example. <br/>

Follow the example source code in <code>src/examples</code> to learn how to use the library.
<br/>
To run examples similar to the paper, the following example calls would do so:<br/>
<b>2D LevelSet, Sphere </b><br/>
<code>examples/Example2 -v -i ../src/test/test_data/sphere_1154verts.ply</code><br/>
<b>2D LevelSet Curvature, Square </b><br/>
<code>$ examples/Example2.exe -v -i ../src/test/test_data/SquareMesh_size16.ply -y curvature -o 0.5 -n 1</code><br/>
<b>3D LevelSet, Torus </b> <br/>
<code>examples/Example1 -v -i ../src/test/test_data/torus -y revolve -n 100</code><br/>
<b>3D LevelSet Curvature, Cube </b><br/>
<code>$ examples/Example1.exe -v -i ../src/test/test_data/CubeMesh_size256step8_correct -y curvature -o 0.5 -n 1 -w 128</code><br/>

**NOTE** All examples output a set of <code>result.vtk</code> VTK files in the current directory 
numbered with the time step iterations. These files are easily viewed via VTK readers like Paraview.
You can clip and add iso-values to more distinctly visualize the result. Opening the set of files
at one time allows you to run a time sequence to view the iteration steps.

Using the Library
==============

A basic usage of the library links to the <code>LEVELSET_CORE</code>
library during build and includes the headers needed, which are usually no more than:

```c++
#include <LevelSet.h>
```

Then a program would setup the LevelSet parameters using the 
<code>"LevelSet object"</code> object and call 
<code>object.solveLevelSet()</code> to generate
the array of vertex values per iteration.

Here is a minimal usage example (using a tet mesh).<br/>
```c++
#include <LevelSet.h>
#include <iostream>
int main(int argc, char *argv[])
{
  LevelSet data(false); // tet mesh, not a tri mesh
  //the below means ~/my_tet_mesh.node & ~/my_tet_mesh.ele
  data.filename_ = "~/my_tet_mesh"; 
  //Run the solver
  data.solveLevelSet(data);
  //now use the result
  data.writeVTK();
  return 0;
}
```

The following accessor functions are available before running the solver:
```c++
void LevelSet::initializeVertices(std::vector<float> values);
void LevelSet::initializeAdvection(std::vector<point> values);
void LevelSet::initializeMesh();
```
The following accessor functions are available after running the solver:
```c++
std::vector < float > LevelSet::getResultAtIteration(size_t i);
size_t LevelSet::numIterations(); 
```
You can also access the results and the mesh directly after running the solver:
```c++
TetMesh * LevelSet::tetMesh_;
TriMesh * LevelSet::triMesh_;
// AND
std::vector < std::vector < LevelsetValueType > > LevelSet::time_values_;
```

<h3>LevelSet Options</h3>

```C++
  class LevelSet {
      bool verbose_;                    //option to set for runtime verbosity [Default false]
      std::string filename_;            //the input tet mesh filename         [Default ../src/test/test_data/sphere334
      int partitionType_;               //0 for unstructured, 1 for square    [Default 0]
      int numSteps_;                    //The number of timed steps to take   [Default 10]
      double timeStep_;                 //The length of time for a time step  [Default 1.0]
      int insideIterations_;            //The number of inner iterations      [Default 1]
      int blockSize_  ;                 //If structured, the block size       [Default 16]
      int sideLengths_;                 //If structured, the cube size        [Default 16]
      LevelsetValueType bandwidth_;     //The algorithm bandwidth             [Default 16.]
      int metisSize_;                   //If unstructured, # of METIS patches [Default 16]
      int isTriMesh_;                   //If this is a triangle mesh          [Default true]
      ...
  };
```
<br/>
You will need to make sure your CMake/Makfile/Build setup knows where 
to point for the library and header files. See the examples and their CMakeLists.txt.<br/><br/>

Testing
==============
The repo comes with a set of regression tests to see if recent changes break 
expected results. To build the tests, you will need to set 
<code>BUILD_TESTING</code> to "ON" in either <code>ccmake</code> or when calling CMake:

```c++
cmake -DBUILD_TESTING=ON ../src
```
After building, run <code>make test</code> or <code>ctest</code> in the build directory to run tests.<br/>
**NOTE** No regression tests have been implemented for this library yet.
<h4>Windows</h4>
The gtest library included in the repo needs to be built with 
forced shared libraries on Windows, so use the following:

```c++
cmake -DBUILD_TESTING=ON -Dgtest_forced_shared_crt=ON ../src
```
Be sure to include all other necessary CMake definitions as annotated above.
