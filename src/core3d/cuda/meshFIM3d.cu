#include <meshFIM3d.h>
#include <tetmesh.h>
#include <Vec.h>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <meshFIM_kernels.h>
#include <cutil.h>
#include <cusp/detail/format_utils.h>
#include <cusp/print.h>
#include <thrust/functional.h>
#include <sstream>

extern "C"
{
#include <metis.h>
}

void meshFIM3d::writeFLD()
{
  int nv = m_meshPtr->vertices.size();
  int nt = m_meshPtr->tets.size();
  FILE* fldfile;
  fldfile = fopen("result.fld", "w+");
  fprintf(fldfile, "SCI\nASC\n2\n{@1 {GenericField<TetVolMesh<TetLinearLgn<Point>>,ConstantBasis<float>,vector<float>> 3 {Field 3 {PropertyManager 2 0 }\n}\n{@2 {TetVolMesh<TetLinearLgn<Point>> 4 {Mesh 2 {PropertyManager 2 0 }\n}\n");
  fprintf(fldfile, "{STLVector 2 %d ", nv);
  for(int i = 0; i < nv; i++)
  {
    fprintf(fldfile, "{%.12f %.12f %.12f}", m_meshPtr->vertices[i][0], m_meshPtr->vertices[i][1], m_meshPtr->vertices[i][2]);
  }
  fprintf(fldfile, "}\n{STLIndexVector 1 %d 8 ", nt * 4);
  for(int i = 0; i < nt; i++)
  {
    fprintf(fldfile, "%d %d %d %d ", m_meshPtr->tets[i][0], m_meshPtr->tets[i][1], m_meshPtr->tets[i][2], m_meshPtr->tets[i][3]);
  }
  fprintf(fldfile, "}\n");
  fprintf(fldfile, "{TetLinearLgn<Point>  1 }\n}\n}{ConstantBasis<float>  1 }\n");
  fprintf(fldfile, "{STLVector 2 %d ", nt);
  for(int i = 0; i < nt; i++)
  {
    fprintf(fldfile, " 0");
  }
  fprintf(fldfile, "}\n}\n}");
  fclose(fldfile);
}

void meshFIM3d::writeVTK(std::vector < std::vector <float> > values)
{
  int nv = m_meshPtr->vertices.size();
  int nt = m_meshPtr->tets.size();
  for (size_t j = 0; j < values.size(); j++) {
    FILE* vtkfile;
    std::stringstream ss;
    ss << "result" << j << ".vtk";
    vtkfile = fopen(ss.str().c_str(), "w+");
    fprintf(vtkfile, "# vtk DataFile Version 3.0\nvtk output\nASCII\nDATASET UNSTRUCTURED_GRID\n");
    fprintf(vtkfile, "POINTS %d float\n", nv);
    for (int i = 0; i < nv; i++)
    {
      fprintf(vtkfile, "%.12f %.12f %.12f\n", m_meshPtr->vertices[i][0], m_meshPtr->vertices[i][1], m_meshPtr->vertices[i][2]);
    }
    fprintf(vtkfile, "CELLS %d %d\n", nt, nt * 5);
    for (int i = 0; i < nt; i++)
    {
      fprintf(vtkfile, "4 %d %d %d %d\n", m_meshPtr->tets[i][0], m_meshPtr->tets[i][1], m_meshPtr->tets[i][2], m_meshPtr->tets[i][3]);
    }

    fprintf(vtkfile, "CELL_TYPES %d\n", nt);
    for (int i = 0; i < nt; i++)
    {
      fprintf(vtkfile, "10\n");
    }
    fprintf(vtkfile, "POINT_DATA %d\nSCALARS traveltime float 1\nLOOKUP_TABLE default\n",
        nv, values.size());
    for (int i = 0; i < values[j].size(); i++) {
      fprintf(vtkfile, "%.12f\n ", values[j][i]);
    }
    fclose(vtkfile);
  }
}

void meshFIM3d::updateT_single_stage_d(float timestep, int niter, IdxVector_d& narrowband, int num_narrowband)
{
  int nn = m_meshPtr->vertices.size();
  int nblocks = num_narrowband;
  int nthreads = largest_ele_part;
  thrust::fill(vertT_out.begin(), vertT_out.end(), 0.0);
  int shared_size = sizeof(float)* 4 * largest_ele_part + sizeof(short)*largest_vert_part*m_largest_num_inside_mem;
  cudaSafeCall((kernel_updateT_single_stage3d << <nblocks, nthreads, shared_size >> >(timestep, CAST(narrowband), largest_ele_part, largest_vert_part, full_num_ele,
          CAST(m_ele_after_permute_d), CAST(m_ele_offsets_d), CAST(m_cadv_local_d),
          nn, CAST(m_vert_offsets_d), CAST(m_vert_after_permute_d), CAST(m_vertT_after_permute_d),
          CAST(m_ele_local_coords_d), m_largest_num_inside_mem, CAST(m_mem_locations), CAST(m_mem_location_offsets),
          CAST(vertT_out))));

  nthreads = largest_vert_part;
  cudaSafeCall((CopyOutBack_levelset3d << <nblocks, nthreads >> >(CAST(narrowband),
          CAST(m_vert_offsets_d), CAST(m_vertT_after_permute_d), CAST(vertT_out))));
}

//Single stage update

void meshFIM3d::updateT_single_stage(float timestep, int nside, int niter, std::vector<int>& narrowband)
{
  vec3 sigma(1.0, 0.0, 1.0);
  float epsilon = 1.0;
  int nv = m_meshPtr->vertices.size();
  int nt = m_meshPtr->tets.size();
  std::vector<float> values(4);
  std::vector<float> up(nv, 0.0);
  std::vector<float> down(nv, 0.0);
  std::vector<vec3> node_grad_phi_up(nv, vec3(0.0, 0.0, 0.0));
  std::vector<float> node_grad_phi_down(nv, 0.0);
  std::vector<float> curv_up(nv, 0.0);


  for(int bandidx = 0; bandidx < narrowband.size(); bandidx++)
  {
    int tidx = narrowband[bandidx];
    for(int j = 0; j < 4; j++)
    {
      values[j] = m_meshPtr->vertT[m_meshPtr->tets[tidx][j]];
    }
    //compute ni normals
    std::vector<vec3> nodes(4);
    nodes[0] = (vec3)m_meshPtr->vertices[m_meshPtr->tets[tidx][0]];
    nodes[1] = (vec3)m_meshPtr->vertices[m_meshPtr->tets[tidx][1]];
    nodes[2] = (vec3)m_meshPtr->vertices[m_meshPtr->tets[tidx][2]];
    nodes[3] = (vec3)m_meshPtr->vertices[m_meshPtr->tets[tidx][3]];
    vec3 v31 = nodes[1] - nodes[3];
    vec3 v32 = nodes[2] - nodes[3];
    vec3 v30 = nodes[0] - nodes[3];
    vec3 crossproduct = v31 CROSS v32;
    float dotproduct = crossproduct DOT v30;
    float volume = fabs(dotproduct) / 6.0;

    //compute inverse of 4 by 4 matrix
    float a11 = nodes[0][0], a12 = nodes[0][1], a13 = nodes[0][2], a14 = 1.0;
    float a21 = nodes[1][0], a22 = nodes[1][1], a23 = nodes[1][2], a24 = 1.0;
    float a31 = nodes[2][0], a32 = nodes[2][1], a33 = nodes[2][2], a34 = 1.0;
    float a41 = nodes[3][0], a42 = nodes[3][1], a43 = nodes[3][2], a44 = 1.0;

    float det =
      a11 * a22 * a33 * a44 + a11 * a23 * a34 * a42 + a11 * a24 * a32 * a43
      + a12 * a21 * a34 * a43 + a12 * a23 * a31 * a44 + a12 * a24 * a33 * a41
      + a13 * a21 * a32 * a44 + a13 * a22 * a34 * a41 + a13 * a24 * a31 * a42
      + a14 * a21 * a33 * a42 + a14 * a22 * a31 * a43 + a14 * a23 * a32 * a41
      - a11 * a22 * a34 * a43 - a11 * a23 * a32 * a44 - a11 * a24 * a33 * a42
      - a12 * a21 * a33 * a44 - a12 * a23 * a34 * a41 - a12 * a24 * a31 * a43
      - a13 * a21 * a34 * a42 - a13 * a22 * a31 * a44 - a13 * a24 * a32 * a41
      - a14 * a21 * a32 * a43 - a14 * a22 * a33 * a41 - a14 * a23 * a31 * a42;

    float b11 = a22 * a33 * a44 + a23 * a34 * a42 + a24 * a32 * a43 - a22 * a34 * a43 - a23 * a32 * a44 - a24 * a33 * a42;
    float b12 = a12 * a34 * a43 + a13 * a32 * a44 + a14 * a33 * a42 - a12 * a33 * a44 - a13 * a34 * a42 - a14 * a32 * a43;
    float b13 = a12 * a23 * a44 + a13 * a24 * a42 + a14 * a22 * a43 - a12 * a24 * a43 - a13 * a22 * a44 - a14 * a23 * a42;
    float b14 = a12 * a24 * a33 + a13 * a22 * a34 + a14 * a23 * a32 - a12 * a23 * a34 - a13 * a24 * a32 - a14 * a22 * a33;

    float b21 = a21 * a34 * a43 + a23 * a31 * a44 + a24 * a33 * a41 - a21 * a33 * a44 - a23 * a34 * a41 - a24 * a31 * a43;
    float b22 = a11 * a33 * a44 + a13 * a34 * a41 + a14 * a31 * a43 - a11 * a34 * a43 - a13 * a31 * a44 - a14 * a33 * a41;
    float b23 = a11 * a24 * a43 + a13 * a21 * a44 + a14 * a23 * a41 - a11 * a23 * a44 - a13 * a24 * a41 - a14 * a21 * a43;
    float b24 = a11 * a23 * a34 + a13 * a24 * a31 + a14 * a21 * a33 - a11 * a24 * a33 - a13 * a21 * a34 - a14 * a23 * a31;


    float b31 = a21 * a32 * a44 + a22 * a34 * a41 + a24 * a31 * a42 - a21 * a34 * a42 - a22 * a31 * a44 - a24 * a32 * a41;
    float b32 = a11 * a34 * a42 + a12 * a31 * a44 + a14 * a32 * a41 - a11 * a32 * a44 - a12 * a34 * a41 - a14 * a31 * a42;
    float b33 = a11 * a22 * a44 + a12 * a24 * a41 + a14 * a21 * a42 - a11 * a24 * a42 - a12 * a21 * a44 - a14 * a22 * a41;
    float b34 = a11 * a24 * a32 + a12 * a21 * a34 + a14 * a22 * a31 - a11 * a22 * a34 - a12 * a24 * a31 - a14 * a21 * a32;

    float b41 = a21 * a33 * a42 + a22 * a31 * a43 + a23 * a32 * a41 - a21 * a32 * a43 - a22 * a33 * a41 - a23 * a31 * a42;
    float b42 = a11 * a32 * a43 + a12 * a33 * a41 + a13 * a31 * a42 - a11 * a33 * a42 - a12 * a31 * a43 - a13 * a32 * a41;
    float b43 = a11 * a23 * a42 + a12 * a21 * a43 + a13 * a22 * a41 - a11 * a22 * a43 - a12 * a23 * a41 - a13 * a21 * a42;
    float b44 = a11 * a22 * a33 + a12 * a23 * a31 + a13 * a21 * a32 - a11 * a23 * a32 - a12 * a21 * a33 - a13 * a22 * a31;

    std::vector<vec4> Arows(4);
    Arows[0] = vec4(b11 / det, b12 / det, b13 / det, b14 / det);
    Arows[1] = vec4(b21 / det, b22 / det, b23 / det, b24 / det);
    Arows[2] = vec4(b31 / det, b32 / det, b33 / det, b34 / det);
    Arows[3] = vec4(b41 / det, b42 / det, b43 / det, b44 / det);

    std::vector<vec3> nablaN(4);
    for(int i = 0; i < 4; i++)
    {
      vec4 RHS(0.0, 0.0, 0.0, 0.0);
      RHS[i] = 1.0;
      nablaN[i][0] = Arows[0] DOT RHS;
      nablaN[i][1] = Arows[1] DOT RHS;
      nablaN[i][2] = Arows[2] DOT RHS;
    }

    //compuate grad of Phi
    vec3 nablaPhi(0.0, 0.0, 0.0);
    for(int i = 0; i < 4; i++)
    {
      nablaPhi[0] += nablaN[i][0] * values[i];
      nablaPhi[1] += nablaN[i][1] * values[i];
      nablaPhi[2] += nablaN[i][2] * values[i];
    }
    float abs_nabla_phi = len(nablaPhi);

    //compute K and Kplus and Kminus
    std::vector<float> Kplus(4);
    std::vector<float> Kminus(4);
    std::vector<float> K(4);
    float Hintegral = 0.0;
    float beta = 0;
    for(int i = 0; i < 4; i++)
    {
      K[i] = volume * (sigma DOT nablaN[i]); // for H(\nabla u) = sigma DOT \nabla u
      Hintegral += K[i] * values[i];
      Kplus[i] = fmax(K[i], (float)0.0);
      Kminus[i] = fmin(K[i], (float)0.0);
      beta += Kminus[i];
    }
    beta = 1.0 / beta;

    if(fabs(Hintegral) > 1e-16)
    {
      std::vector<float> delta(4);
      for(int i = 0; i < 4; i++)
      {
        delta[i] = Kplus[i] * beta * (Kminus[0] * (values[i] - values[0]) + Kminus[1] * 
          (values[i] - values[1]) + Kminus[2] * (values[i] - values[2]) + Kminus[3] * (values[i] - values[3]));
      }

      std::vector<float> alpha(4);
      for(int i = 0; i < 4; i++)
      {
        alpha[i] = delta[i] / Hintegral;
      }

      float theta = 0;
      for(int i = 0; i < 4; i++)
      {
        theta += fmax((float)0.0, alpha[i]);
      }

      std::vector<float> alphatuda(4);
      for(int i = 0; i < 4; i++)
      {
        alphatuda[i] = fmax(alpha[i], (float)0.0) / theta;
      }

      for(int i = 0; i < 4; i++)
      {
        up[m_meshPtr->tets[tidx][i]] += alphatuda[i] * Hintegral;
        down[m_meshPtr->tets[tidx][i]] += alphatuda[i] * volume;
        node_grad_phi_up[m_meshPtr->tets[tidx][i]] += volume* nablaPhi;
        node_grad_phi_down[m_meshPtr->tets[tidx][i]] += volume;
        curv_up[m_meshPtr->tets[tidx][i]] += volume * ((nablaN[i] DOT nablaN[i]) / abs_nabla_phi * values[i] +
            (nablaN[i] DOT nablaN[(i + 1) % 4]) / abs_nabla_phi * values[(i + 1) % 4] +
            (nablaN[i] DOT nablaN[(i + 2) % 4]) / abs_nabla_phi * values[(i + 2) % 4] +
            (nablaN[i] DOT nablaN[(i + 3) % 4]) / abs_nabla_phi * values[(i + 3) % 4]);
      }
    }
  }

  for(int vidx = 0; vidx < nv; vidx++)
  {
    float eikonal = up[vidx] / down[vidx];
    float curvature = curv_up[vidx] / node_grad_phi_down[vidx];
    float node_eikonal = len(node_grad_phi_up[vidx]) / node_grad_phi_down[vidx];
    if(fabs(down[vidx]) > 1e-16)
    {
      m_meshPtr->vertT[vidx] -= epsilon * node_eikonal * curvature * timestep;
    }
  }
}

void meshFIM3d::GraphPartition_Square(int squareLength, int squareWidth, int squareHeight,
    int blockLength, int blockWidth, int blockHeight, bool verbose)
{
  int nn = m_meshPtr->vertices.size();
  int numBlockLength = ceil((float)squareLength / blockLength);
  int numBlockWidth = ceil((float)squareWidth / blockWidth);
  int numBlockHeight = ceil((float)squareHeight / blockHeight);
  int numBlock = numBlockLength * numBlockWidth*numBlockHeight;
  npart_h = IdxVector_h(nn);
  nparts = numBlock;

  int edgeCount = 0;
  for(int vIt = 0; vIt < nn; vIt++)
  {
    edgeCount += m_meshPtr->neighbors[vIt].size();
  }

  m_largest_num_inside_mem = 0;
  for(int i = 0; i < nn; i++)
  {
    if(m_meshPtr->adjacenttets[i].size() > m_largest_num_inside_mem)
      m_largest_num_inside_mem = m_meshPtr->adjacenttets[i].size();
  }
  if (verbose)
    printf("m_largest_num_inside_mem = %d\n", m_largest_num_inside_mem);

  //Allocating storage for array values of adjacency
  int* xadj = new int[nn + 1];
  int* adjncy = new int[edgeCount];

  // filling the arrays:
  xadj[0] = 0;
  int idx = 0;
  IdxVector_h neighbor_sizes(nn);
  // Populating the arrays:
  for(int i = 1; i < nn + 1; i++)
  {
    neighbor_sizes[i - 1] = m_meshPtr->neighbors[i - 1].size();
    xadj[i] = xadj[i - 1] + m_meshPtr->neighbors[i - 1].size();
    for(int j = 0; j < m_meshPtr->neighbors[i - 1].size(); j++)
    {
      adjncy[idx++] = m_meshPtr->neighbors[i - 1][j];
    }
  }

  m_neighbor_sizes_d = neighbor_sizes;

  for(int k = 0; k < squareHeight; k++)
    for(int i = 0; i < squareWidth; i++)
      for(int j = 0; j < squareLength; j++)
      {
        int index = k * squareLength * squareWidth + i * squareLength + j;
        int k2 = k;
        int i2 = i;
        int j2 = j;
        npart_h[index] = (k2 / blockHeight) * numBlockLength *
          numBlockWidth + (i2 / blockWidth) * numBlockLength + (j2 / blockLength);
      }

  m_xadj_d = IdxVector_d(&xadj[0], &xadj[nn + 1]);
  m_adjncy_d = IdxVector_d(&adjncy[0], &adjncy[edgeCount]);

  IdxVector_h part_sizes(nparts, 0);
  if (verbose) {
    std::cout << npart_h.size() << std::endl;
    std::cout << part_sizes.size() << std::endl;
    std::cout << nn << std::endl;
  }
  for(int i = 0; i < nn; i++)
  {
    part_sizes[npart_h[i]]++;
  }
  int min_part_size = thrust::reduce(part_sizes.begin(), part_sizes.end(),
      100000000, thrust::minimum<int>());
  largest_vert_part = thrust::reduce(part_sizes.begin(), part_sizes.end(),
      -1, thrust::maximum<int>());
  if(verbose)
    printf("Largest vertex partition size is: %d\n", largest_vert_part);
  if(min_part_size == 0)
    if(verbose)
      printf("Min partition size is 0!!\n");
  delete[] xadj;
  delete[] adjncy;
}

void meshFIM3d::Partition_METIS(int metissize, bool verbose)
{
  int options[10], pnumflag = 0, wgtflag = 0;
  options[0] = 0;
  int edgecut;
  int nn = m_meshPtr->vertices.size();
  npart_h = IdxVector_h(nn);
  nparts = ceil((float)nn / (float)metissize);

  // Counting up edges for adjacency:
  int edgeCount = 0;
  for(int vIt = 0; vIt < nn; vIt++)
  {
    edgeCount += m_meshPtr->neighbors[vIt].size();// m_meshPtr->neighbors[vIt].size()：一个节点周围节点数
  }

  m_largest_num_inside_mem = 0;
  for(int i = 0; i < nn; i++)
  {
    if(m_meshPtr->adjacenttets[i].size() > m_largest_num_inside_mem)
      m_largest_num_inside_mem = m_meshPtr->adjacenttets[i].size();
  }//找一个节点周围最多有多少个单元
  if (verbose)
    printf("m_largest_num_inside_mem = %d\n", m_largest_num_inside_mem);


  //Allocating storage for array values of adjacency
  int* xadj = new int[nn + 1];
  int* adjncy = new int[edgeCount];

  // filling the arrays:
  xadj[0] = 0;
  int idx = 0;
  IdxVector_h neighbor_sizes(nn);
  // Populating the arrays:
  for(int i = 1; i < nn + 1; i++)
  {
    neighbor_sizes[i - 1] = m_meshPtr->neighbors[i - 1].size();
    xadj[i] = xadj[i - 1] + m_meshPtr->neighbors[i - 1].size();
    for(int j = 0; j < m_meshPtr->neighbors[i - 1].size(); j++)
    {
      adjncy[idx++] = m_meshPtr->neighbors[i - 1][j];
    }
  }

  m_neighbor_sizes_d = neighbor_sizes;

  METIS_PartGraphKway(&nn, xadj, adjncy, NULL, NULL, &wgtflag, &pnumflag,
      &nparts, options, &edgecut, thrust::raw_pointer_cast(&npart_h[0]));

  m_xadj_d = IdxVector_d(&xadj[0], &xadj[nn + 1]);
  m_adjncy_d = IdxVector_d(&adjncy[0], &adjncy[edgeCount]);

  IdxVector_h part_sizes(nparts, 0);
  for(int i = 0; i < nn; i++)
  {
    part_sizes[npart_h[i]]++;
  }
  int min_part_size = thrust::reduce(part_sizes.begin(), part_sizes.end(), 100000000, thrust::minimum<int>());
  largest_vert_part = thrust::reduce(part_sizes.begin(), part_sizes.end(), -1, thrust::maximum<int>());
  if (verbose)
    printf("Largest vertex partition size is: %d\n", largest_vert_part);
  if(min_part_size == 0)
    if (verbose)
      printf("Min partition size is 0!!\n");
  delete [] xadj;
  delete [] adjncy;
}

void meshFIM3d::InitPatches(bool verbose)
{
  int ne = m_meshPtr->tets.size();
  int nn = m_meshPtr->vertices.size();
  ele_d = IdxVector_d(4 * ne);
  ele_h = IdxVector_h(4 * ne);
  vert_d = Vector_d(3 * nn);
  m_vert_after_permute_d = Vector_d(3 * nn);
  Vector_h vert_h(3 * nn);
  for(int eidx = 0; eidx < ne; eidx++)
  {
    for(int i = 0; i < 4; i++)
      ele_h[i * ne + eidx] = m_meshPtr->tets[eidx][i]; //interleaved storage
  }
  for(int vidx = 0; vidx < nn; vidx++)
  {
    for(int i = 0; i < 3; i++)
      vert_h[i * nn + vidx] = m_meshPtr->vertices[vidx][i]; //interleaved storage
  }
  ele_d = ele_h;
  vert_d = vert_h;
  m_npart_d = IdxVector_d(npart_h.begin(), npart_h.end());
  m_part_label_d = IdxVector_d(m_npart_d.begin(), m_npart_d.end());
  int nthreads = 256;
  int nblocks = min((int)ceil((float)ne / nthreads), 65535);
  cudaSafeCall((kernel_compute_ele_npart3d << <nblocks, nthreads >> >(ne,
          thrust::raw_pointer_cast(&m_npart_d[0]), thrust::raw_pointer_cast(&ele_d[0]),
          thrust::raw_pointer_cast(&ele_label_d[0]))));


  full_num_ele = thrust::reduce(ele_label_d.begin(), ele_label_d.end());
  if(verbose)
    printf("full_num_ele = %d\n", full_num_ele);
  ele_offsets_d[0] = 0;
  thrust::inclusive_scan(ele_label_d.begin(), ele_label_d.end(), ele_offsets_d.begin() + 1);
  ele_full_label = IdxVector_d(full_num_ele);
  ele_permute = IdxVector_d(full_num_ele);

  cudaSafeCall((kernel_fill_ele_label3d << <nblocks, nthreads >> >(ne, thrust::raw_pointer_cast(&ele_permute[0]),
          thrust::raw_pointer_cast(&ele_offsets_d[0]),
          thrust::raw_pointer_cast(&m_npart_d[0]), thrust::raw_pointer_cast(&ele_d[0]),
          thrust::raw_pointer_cast(&ele_full_label[0]))));

  clock_t starttime, endtime;
  double duration;
  starttime = clock();
  thrust::sort_by_key(ele_full_label.begin(), ele_full_label.end(), ele_permute.begin());
  cudaThreadSynchronize();
  endtime = clock();
  duration = (double)(endtime - starttime) / (double)CLOCKS_PER_SEC;
  if(verbose)
    printf("Sorting time : %.10lf s\n", duration);
  m_ele_offsets_d = IdxVector_d(nparts + 1);
  ones = IdxVector_d(full_num_ele, 1);
  tmp = IdxVector_d(full_num_ele);
  reduce_output = IdxVector_d(full_num_ele);
  thrust::reduce_by_key(ele_full_label.begin(),
      ele_full_label.end(), ones.begin(), tmp.begin(), reduce_output.begin());
  largest_ele_part = thrust::reduce(reduce_output.begin(),
      reduce_output.begin() + nparts, -1, thrust::maximum<int>());
  if(verbose)
    printf("Largest element partition size is: %d\n", largest_ele_part);
  if(largest_ele_part > 1024)
  {
    printf("Error: largest_ele_part > 1024 !!\n");
    exit(0);
  }
  m_ele_offsets_d[0] = 0;
  thrust::inclusive_scan(reduce_output.begin(), reduce_output.begin() + nparts,
      m_ele_offsets_d.begin() + 1);
}

void meshFIM3d::InitPatches2()
{
  int ne = m_meshPtr->tets.size();
  int nn = m_meshPtr->vertices.size();
  IdxVector_d vert_permute(nn, 0);
  IdxVector_d vert_ipermute(nn, 0);
  int nthreads = 256;
  int nblocks = min((int)ceil((float)nn / nthreads), 65535);
  cudaSafeCall((kernel_fill_sequence3d << <nblocks, nthreads >> >(nn, CAST(vert_permute))));
  thrust::sort_by_key(m_part_label_d.begin(), m_part_label_d.end(), vert_permute.begin());
  nblocks = min((int)ceil((float)nn / nthreads), 65535);
  cudaSafeCall((kernel_compute_vert_ipermute3d << <nblocks, nthreads >> >(nn,
          thrust::raw_pointer_cast(&vert_permute[0]), thrust::raw_pointer_cast(&vert_ipermute[0]))));

  m_vert_permute_d = IdxVector_d(vert_permute);
  m_vert_offsets_d = IdxVector_d(nparts + 1);
  cusp::detail::indices_to_offsets(m_part_label_d, m_vert_offsets_d);

  //permute the vert and ele values
  m_ele_after_permute_d = IdxVector_d(4 * full_num_ele);
  m_vertT_after_permute_d = Vector_d(nn);
  nblocks = min((int)ceil((float)full_num_ele / nthreads), 65535);
  cudaSafeCall((kernel_ele_and_vert3d << <nblocks, nthreads >> >(full_num_ele, ne,
          thrust::raw_pointer_cast(&ele_d[0]), thrust::raw_pointer_cast(&m_ele_after_permute_d[0]),
          thrust::raw_pointer_cast(&ele_permute[0]),
          nn, thrust::raw_pointer_cast(&vert_d[0]), thrust::raw_pointer_cast(&m_vert_after_permute_d[0]),
          thrust::raw_pointer_cast(&m_vertT_d[0]), thrust::raw_pointer_cast(&m_vertT_after_permute_d[0]),
          CAST(vert_permute),
          thrust::raw_pointer_cast(&vert_ipermute[0]))));

  //compute the local coords for each element
  m_ele_local_coords_d = Vector_d(6 * full_num_ele);
  m_cadv_local_d = Vector_d(3 * full_num_ele);
  nthreads = 256;
  nblocks = min((int)ceil((float)full_num_ele / nthreads), 65535);
  cudaSafeCall((kernel_compute_local_coords3d << <nblocks, nthreads >> >(full_num_ele, nn,
          thrust::raw_pointer_cast(&m_ele_after_permute_d[0]), thrust::raw_pointer_cast(&m_ele_offsets_d[0]),
          thrust::raw_pointer_cast(&m_vert_after_permute_d[0]),
          thrust::raw_pointer_cast(&m_ele_local_coords_d[0]),
          CAST(m_cadv_global_d), CAST(m_cadv_local_d))));
  //Generate redution list

  m_mem_locations = IdxVector_d(4 * full_num_ele);
  IdxVector_d tmp2 = m_ele_after_permute_d;
  thrust::sequence(m_mem_locations.begin(), m_mem_locations.end(), 0);
  thrust::sort_by_key(tmp2.begin(), tmp2.end(), m_mem_locations.begin());
  m_mem_location_offsets = IdxVector_d(nn + 1);
  cusp::detail::indices_to_offsets(tmp2, m_mem_location_offsets);

}

void meshFIM3d::GenerateBlockNeighbors()
{

  //Generate block neighbors
  // Declaring temporary vectors:
  adjacencyBlockLabel = IdxVector_d(m_adjncy_d.size(), 0);
  blockMappedAdjacency = IdxVector_d(m_adjncy_d.size(), 0);

  mapAdjacencyToBlock(m_xadj_d, m_adjncy_d, adjacencyBlockLabel, blockMappedAdjacency, m_npart_d);
  // Zip up the block label and block mapped vectors and sort:
  thrust::sort(thrust::make_zip_iterator(thrust::make_tuple(adjacencyBlockLabel.begin(), blockMappedAdjacency.begin())),
      thrust::make_zip_iterator(thrust::make_tuple(adjacencyBlockLabel.end(), blockMappedAdjacency.end())));

  // Remove Duplicates and resize:
  int newSize = thrust::unique(thrust::make_zip_iterator(thrust::make_tuple(adjacencyBlockLabel.begin(), blockMappedAdjacency.begin())),
      thrust::make_zip_iterator(thrust::make_tuple(adjacencyBlockLabel.end(), blockMappedAdjacency.end()))) -
    thrust::make_zip_iterator(thrust::make_tuple(adjacencyBlockLabel.begin(), blockMappedAdjacency.begin()));


  adjacencyBlockLabel.resize(newSize);
  blockMappedAdjacency.resize(newSize);
  getPartIndicesNegStart(adjacencyBlockLabel, m_block_xadj_d);
  m_block_adjncy_d.resize(blockMappedAdjacency.size() - 1);
  thrust::copy(blockMappedAdjacency.begin() + 1, blockMappedAdjacency.end(), m_block_adjncy_d.begin());
}

std::vector <std::vector <float> > meshFIM3d::GenerateData(
    char* filename, int nsteps, float timestep, int inside_niter,
    int nside, int block_size, float bandwidth, int part_type,
    int metis_size, bool verbose)
{
  if (verbose)
    printf("Starting meshFIM::GenerateData\n");
  int nv = m_meshPtr->vertices.size();
  int nt = m_meshPtr->tets.size();

  int squareLength = nside;
  int squareWidth = nside;
  int squareDepth = nside;
  int squareBlockLength = block_size;
  int squareBlockWidth = block_size;
  int squareBlockDepth = block_size;
  //  float starttime, endtime, duration;
  clock_t starttime, endtime, starttime1, endtime1;
  float duration, duration1 = 0.0, duration2 = 0.0;

  if(part_type == 1)
    GraphPartition_Square(squareLength, squareWidth, squareDepth,
        squareBlockLength, squareBlockWidth, squareBlockDepth, verbose);
  else //partition with METIS
  {
    Partition_METIS(metis_size, verbose);
  }
  //Initialize the values
  Vector_h h_vertT(nv);
  for(int i = 0; i < nv; i++)
  {
    h_vertT[i] = m_meshPtr->vertT[i];
  }
  m_vertT_d = h_vertT;
  starttime = clock();
  //Init patches
  InitPatches(verbose);
  Vector_h cadv_h(3 * full_num_ele,0);
  IdxVector_h ele_permute_h = IdxVector_h(ele_permute);
  for (int i = 0; i < full_num_ele; i++) {
    size_t tetIdx = static_cast<size_t>(ele_permute_h[i]);
    cadv_h[0 * full_num_ele + i] = m_meshPtr->normals[tetIdx][0];
    cadv_h[1 * full_num_ele + i] = m_meshPtr->normals[tetIdx][1];
    cadv_h[2 * full_num_ele + i] = m_meshPtr->normals[tetIdx][2];
  }

  m_cadv_global_d = Vector_d(cadv_h);
  InitPatches2(); 
  GenerateBlockNeighbors();
  if (verbose)
    printf("After  preprocessing\n");
  endtime = clock();
  duration = (float)(endtime - starttime) / CLOCKS_PER_SEC;
  if (verbose)
    printf("pre processing time : %.10lf s\n", duration);

  //Inite redistance
  m_redist = new redistance3d(m_meshPtr, nparts, m_block_xadj_d, m_block_adjncy_d);

  //////////////////////////update values///////////////////////////////////////////
  IdxVector_d narrowband_d(nparts);
  int num_narrowband = 0;

  std::vector <std::vector <float> >  ans;
  ans.push_back(m_meshPtr->vertT);

  starttime = clock();
  for(int stepcount = 0; stepcount < nsteps; stepcount++)
  {
    m_redist->FindSeedPoint(narrowband_d, num_narrowband, m_meshPtr, m_vertT_after_permute_d, nparts, largest_vert_part, largest_ele_part, m_largest_num_inside_mem, full_num_ele,
        m_vert_after_permute_d, m_vert_offsets_d, m_ele_after_permute_d, m_ele_offsets_d, m_ele_local_coords_d, m_mem_location_offsets, m_mem_locations,
        m_part_label_d, m_block_xadj_d, m_block_adjncy_d);

    m_redist->ReInitTsign(m_meshPtr, m_vertT_after_permute_d, nparts, largest_vert_part, largest_ele_part, m_largest_num_inside_mem, full_num_ele,
        m_vert_after_permute_d, m_vert_offsets_d, m_ele_after_permute_d, m_ele_offsets_d, m_ele_local_coords_d, m_mem_location_offsets, m_mem_locations,
        m_part_label_d, m_block_xadj_d, m_block_adjncy_d);
    starttime1 = clock();
    m_redist->GenerateData(narrowband_d, num_narrowband, bandwidth, stepcount, m_meshPtr, m_vertT_after_permute_d, nparts, largest_vert_part, largest_ele_part, m_largest_num_inside_mem, full_num_ele,
        m_vert_after_permute_d, m_vert_offsets_d, m_ele_after_permute_d, m_ele_offsets_d, m_ele_local_coords_d, m_mem_location_offsets, m_mem_locations,
        m_part_label_d, m_block_xadj_d, m_block_adjncy_d, verbose);
    cudaThreadSynchronize();
    endtime1 = clock();
    duration1 += endtime1 - starttime1;
    if (num_narrowband == 0) {
      std::cout << "NOTE: Ending at timestep " << stepcount <<
        " due to zero narrow band." << std::endl;
      break;
    }
    starttime1 = clock();
    for(int niter = 0; niter < inside_niter; niter++)
      updateT_single_stage_d(timestep, stepcount, narrowband_d, num_narrowband);

    cudaThreadSynchronize();
    endtime1 = clock();
    duration2 += endtime1 - starttime1;
    ///////////////////done updating/////////////////////////////////////////////////
    int nthreads = 256;
    int nblocks = min((int)ceil((float)nv / nthreads), 655535);
    cudaSafeCall((kernel_compute_vertT_before_permute3d << <nblocks, nthreads >> >(nv, 
      CAST(m_vert_permute_d), CAST(m_vertT_after_permute_d), CAST(tmp_vertT_before_permute_d))));
    Vector_h vertT_before_permute_h = tmp_vertT_before_permute_d;
    for(int i = 0; i < nv; i++)
    {
      m_meshPtr->vertT[i] = vertT_before_permute_h[i];
    }
    ans.push_back(m_meshPtr->vertT);
  }

  cudaThreadSynchronize();
  endtime = clock();
  if (verbose)
    printf("redistance time : %.10lf s\n", (float)duration1 / CLOCKS_PER_SEC);
  if (verbose)
    printf("levelset update time : %.10lf s\n", (float)duration2 / CLOCKS_PER_SEC);
  duration = (double)(endtime - starttime) / (double)CLOCKS_PER_SEC;
  if (verbose)
    printf("Processing time : %.10lf s\n", duration);
  return ans;
}

void meshFIM3d::getPartIndicesNegStart(IdxVector_d& sortedPartition, IdxVector_d& partIndices)
{
  // Sizing the array:
  int maxPart = sortedPartition[sortedPartition.size() - 1];
  partIndices.resize(maxPart + 2, 0);

  // Figuring out block sizes for kernel call:
  int size = sortedPartition.size();
  int blockSize = 256;
  int nBlocks = size / blockSize + (size % blockSize == 0 ? 0 : 1);

  // Getting pointers
  int *sortedPartition_d = thrust::raw_pointer_cast(&sortedPartition[0]);
  int *partIndices_d = thrust::raw_pointer_cast(&partIndices[0]);

  // Calling kernel to find indices for each part:
  findPartIndicesNegStartKernel3d << < nBlocks, blockSize >> > (size, sortedPartition_d, partIndices_d);
  partIndices[partIndices.size() - 1] = size - 1;
}

void meshFIM3d::mapAdjacencyToBlock(IdxVector_d &adjIndexes, IdxVector_d &adjacency, 
  IdxVector_d &adjacencyBlockLabel, IdxVector_d &blockMappedAdjacency, IdxVector_d &fineAggregate)
{
  int size = adjIndexes.size() - 1;
  // Get pointers:adjacencyIn
  int *adjIndexes_d = thrust::raw_pointer_cast(&adjIndexes[0]);
  int *adjacency_d = thrust::raw_pointer_cast(&adjacency[0]);
  int *adjacencyBlockLabel_d = thrust::raw_pointer_cast(&adjacencyBlockLabel[0]);
  int *blockMappedAdjacency_d = thrust::raw_pointer_cast(&blockMappedAdjacency[0]);
  int *fineAggregate_d = thrust::raw_pointer_cast(&fineAggregate[0]);

  // Figuring out block sizes for kernel call:
  int blockSize = 256;
  int nBlocks = size / blockSize + (size % blockSize == 0 ? 0 : 1);

  // Calling kernel:
  mapAdjacencyToBlockKernel3d << < nBlocks, blockSize >> > (size, adjIndexes_d, adjacency_d, 
    adjacencyBlockLabel_d, blockMappedAdjacency_d, fineAggregate_d);
}

